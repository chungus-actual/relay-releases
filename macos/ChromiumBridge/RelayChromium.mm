#import <AppKit/AppKit.h>
#include <QApplication>
#include <QWebEngineView>
#include <QWebEnginePage>
#include <QWebEngineProfile>
#include <QWebEngineClientHints>
#include <QRegularExpression>
#include <QWebEngineSettings>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>
#include <QWebEngineHistory>
#include <QWebEngineNotification>
#include <QWebEnginePermission>
#include <QWebEngineDownloadRequest>
#include <QtWebEngineCore/qtwebenginecoreglobal.h>
#include <QWindow>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QPointer>
#include <QFileInfo>
#include <QDir>
#include <QUuid>
#include <QTimer>
#include <QSet>
#include <unordered_map>
#include <algorithm>
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>

using Callback = int (*)(void*, const char*, const char*);
struct Browser;
struct Page : QWebEnginePage {
    Browser* owner;
    int number;
    Page(Browser* owner, int number, QWebEngineProfile* profile, QObject* parent);
    bool acceptNavigationRequest(const QUrl&, NavigationType, bool) override;
    QWebEnginePage* createWindow(WebWindowType) override;
    void javaScriptConsoleMessage(JavaScriptConsoleMessageLevel, const QString&, int, const QString&) override;
};
struct Browser : QObject {
    Callback callback;
    void* user;
    QWebEngineProfile* profile;
    QWebEngineView* view;
    QWindow* foreign;
    QMap<int, QPointer<Page>> pages;
    QMap<int, QPointer<QWebEngineView>> views;
    QMap<QString, QWebEnginePermission> permissions;
    QMap<QString, QPointer<QWebEngineDownloadRequest>> downloads;
    QMap<QString, QPair<int, QString>> evaluations;
    std::unordered_map<std::string, std::unique_ptr<QWebEngineNotification>> notifications;
    bool muted = false, keepLive = true;
    int nextPage = 1;

    int emitEvent(const char* name, const QJsonObject& value) {
        if (!callback) return 0;
        QByteArray data = QJsonDocument(value).toJson(QJsonDocument::Compact);
        return callback(user, name, data.constData());
    }
    void state(Page* page) {
        emitEvent("state", {{"page",page->number},{"url",page->url().toString()},{"title",page->title()},
            {"back",page->history()->canGoBack()},{"forward",page->history()->canGoForward()},
            {"pid",double(page->renderProcessPid())},{"audible",page->recentlyAudible()},
            {"muted",page->isAudioMuted()},{"zoom",page->zoomFactor()},
            {"sleeping",page->lifecycleState()!=QWebEnginePage::LifecycleState::Active}});
    }
    Page* makePage(QWebEngineView* widget, int number) {
        auto page = new Page(this, number, profile, widget);
        pages[number] = page; views[number] = widget;
        widget->setPage(page);
        page->setAudioMuted(muted);
        connect(page,&QWebEnginePage::titleChanged,this,[this,page]{state(page);});
        connect(page,&QWebEnginePage::urlChanged,this,[this,page]{state(page);});
        connect(page,&QWebEnginePage::loadStarted,this,[this,page]{emitEvent("loading",{{"page",page->number}});state(page);});
        connect(page,&QWebEnginePage::loadFinished,this,[this,page](bool ok){state(page);emitEvent("loaded",{{"page",page->number},{"ok",ok}});});
        connect(page,&QWebEnginePage::renderProcessPidChanged,this,[this,page]{state(page);});
        connect(page,&QWebEnginePage::recentlyAudibleChanged,this,[this,page]{state(page);});
        connect(page,&QWebEnginePage::lifecycleStateChanged,this,[this,page]{state(page);});
        connect(page,&QWebEnginePage::recommendedStateChanged,this,[this,page](QWebEnginePage::LifecycleState value){
            if (!keepLive) page->setLifecycleState(value==QWebEnginePage::LifecycleState::Discarded ? QWebEnginePage::LifecycleState::Frozen : value);
        });
        connect(page,&QWebEnginePage::renderProcessTerminated,this,[this,page](auto,int){emitEvent("terminated",{{"page",page->number}});});
        connect(page,&QWebEnginePage::permissionRequested,this,[this,page](QWebEnginePermission request){
            auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
            permissions.insert(id,request);
            emitEvent("permission",{{"id",id},{"page",page->number},{"origin",request.origin().toString()},{"type",int(request.permissionType())}});
        });
        connect(page,&QWebEnginePage::windowCloseRequested,this,[this,number]{if(number && views.value(number)) views.value(number)->close();});
        if(number) {
            widget->setAttribute(Qt::WA_DeleteOnClose);
            connect(widget,&QObject::destroyed,this,[this,number]{pages.remove(number);views.remove(number);emitEvent("closed",{{"page",number}});});
        }
        return page;
    }
    Browser(const QString& path, void* parentView, void* context, Callback handler):callback(handler),user(context) {
        if(path.isEmpty()) profile=new QWebEngineProfile(this);
        else {
            profile=new QWebEngineProfile(QFileInfo(path).fileName(),this);
            profile->setPersistentStoragePath(path+"/Data");profile->setCachePath(path+"/Cache");
            profile->setPersistentCookiesPolicy(QWebEngineProfile::ForcePersistentCookies);
        }
        // Keep the real Chromium/platform version, without a Qt-specific browser
        // token that can cause sites to select an embedded/mobile experience.
        auto userAgent = profile->httpUserAgent();
        userAgent.remove(QRegularExpression(QStringLiteral(" QtWebEngine/[^ ]+")));
        profile->setHttpUserAgent(userAgent);
        profile->clientHints()->setIsMobile(false);
        profile->clientHints()->setFormFactors({QStringLiteral("Desktop")});
        profile->setNotificationPresenter([this](std::unique_ptr<QWebEngineNotification> notification){
            auto id=QUuid::createUuid().toString(QUuid::WithoutBraces);
            auto data=QJsonObject{{"id",id},{"title",notification->title()},{"body",notification->message()},{"origin",notification->origin().toString()}};
            notification->show();
            if(notifications.size()>=60) {notifications.begin()->second->close();notifications.erase(notifications.begin());}
            notifications[id.toStdString()]=std::move(notification);
            emitEvent("notification",data);
        });
        connect(profile,&QWebEngineProfile::downloadRequested,this,[this](QWebEngineDownloadRequest* request){
            auto id=QUuid::createUuid().toString(QUuid::WithoutBraces);
            downloads[id]=request;
            auto update=[this,id,request]{emitEvent("download",{{"id",id},{"state",int(request->state())},
                {"received",double(request->receivedBytes())},{"total",double(request->totalBytes())},
                {"paused",request->isPaused()},{"finished",request->isFinished()},{"error",request->interruptReasonString()}});};
            connect(request,&QWebEngineDownloadRequest::stateChanged,this,update);
            connect(request,&QWebEngineDownloadRequest::receivedBytesChanged,this,update);
            connect(request,&QWebEngineDownloadRequest::totalBytesChanged,this,update);
            connect(request,&QWebEngineDownloadRequest::isPausedChanged,this,update);
            emitEvent("downloadRequest",{{"id",id},{"name",request->suggestedFileName()},{"url",request->url().toString()}});
        });
        view=new QWebEngineView;
        const auto bounds = [(__bridge NSView*)parentView bounds];
        view->resize(std::max(1, int(bounds.size.width)), std::max(1, int(bounds.size.height)));
        makePage(view,0);
        view->winId();
        foreign=QWindow::fromWinId(reinterpret_cast<WId>(parentView));
        view->windowHandle()->setParent(foreign);
        view->show();
    }
    ~Browser() override {
        callback=nullptr;
        for(auto& pair:notifications) pair.second->close();
        for(auto page:pages) if(page) page->disconnect(this);
        auto widgets=views.values();views.clear();pages.clear();
        for(auto widget:widgets) if(widget) delete widget;
        delete foreign;
        delete profile;
    }
};
Page::Page(Browser* owner,int number,QWebEngineProfile* profile,QObject* parent):QWebEnginePage(profile,parent),owner(owner),number(number){}
bool Page::acceptNavigationRequest(const QUrl& url,NavigationType type,bool main) {
    return owner->emitEvent("navigate",{{"page",number},{"url",url.toString()},{"link",type==NavigationTypeLinkClicked},{"main",main}})!=0;
}
QWebEnginePage* Page::createWindow(WebWindowType) {
    auto widget=new QWebEngineView;
    auto page=owner->makePage(widget,owner->nextPage++);
    widget->resize(720,760);widget->show();
    owner->emitEvent("popup",{{"page",page->number}});
    return page;
}
void Page::javaScriptConsoleMessage(JavaScriptConsoleMessageLevel,const QString& message,int,const QString&) {
    if(!message.startsWith("relay-eval:"))return;
    auto split=message.indexOf(':',11);if(split<0)return;
    auto token=message.mid(11,split-11);
    auto it=owner->evaluations.find(token);
    if(it==owner->evaluations.end() || it->first!=number)return;
    auto id=it->second;owner->evaluations.erase(it);
    auto document=QJsonDocument::fromJson(message.mid(split+1).toUtf8());
    owner->emitEvent("evaluation",{{"id",id},{"result",document.object().value("value")},{"error",document.object().value("error")}});
}
extern "C" {
__attribute__((visibility("default"))) int relay_chromium_initialize(const char* plugins) {
    if(qApp)return 1;
    QCoreApplication::setAttribute(Qt::AA_PluginApplication);
    QCoreApplication::addLibraryPath(QString::fromUtf8(plugins));
    static int argc=1;static char name[]="Relay";static char* argv[]={name,nullptr};
    new QApplication(argc,argv);QApplication::setQuitOnLastWindowClosed(false);
    QCoreApplication::setApplicationName("Relay");
    qInfo("Relay Chromium: Qt %s, Chromium %s, security patches %s", qVersion(), qWebEngineChromiumVersion(), qWebEngineChromiumSecurityPatchVersion());
    return 1;
}
__attribute__((visibility("default"))) void* relay_chromium_create(const char* path,void* view,void* user,Callback callback) {
    return new Browser(QString::fromUtf8(path),view,user,callback);
}
__attribute__((visibility("default"))) void relay_chromium_destroy(void* handle) {delete static_cast<Browser*>(handle);}
__attribute__((visibility("default"))) void relay_chromium_command(void* handle,const char* name,const char* payload) {
    auto browser=static_cast<Browser*>(handle);if(!browser)return;
    QString command=QString::fromUtf8(name);auto data=QJsonDocument::fromJson(payload).object();
    auto page=browser->pages.value(data.value("page").toInt());
    if(command=="state" && page)browser->state(page);
    else if(command=="load" && page)page->load(QUrl(data["url"].toString()));
    else if(command=="html" && page)page->setHtml(data["html"].toString(),QUrl(data["url"].toString()));
    else if(command=="reload" && page)page->triggerAction(QWebEnginePage::Reload);
    else if(command=="back" && page)page->triggerAction(QWebEnginePage::Back);
    else if(command=="forward" && page)page->triggerAction(QWebEnginePage::Forward);
    else if(command=="zoom") {for(auto p:browser->pages)if(p)p->setZoomFactor(data["value"].toDouble(1));}
    else if(command=="mute") {browser->muted=data["value"].toBool();for(auto p:browser->pages)if(p)p->setAudioMuted(browser->muted);}
    else if(command=="awake") {
        browser->keepLive=data["value"].toBool();
        for(auto p:browser->pages)if(p)p->setLifecycleState(browser->keepLive ? QWebEnginePage::LifecycleState::Active :
            (p->recommendedState()==QWebEnginePage::LifecycleState::Discarded ? QWebEnginePage::LifecycleState::Frozen : p->recommendedState()));
    }
    else if(command=="visible")browser->view->setVisible(data["value"].toBool());
    else if(command=="resize")browser->view->resize(data["width"].toInt(),data["height"].toInt());
    else if(command=="script") {
        QWebEngineScript script;script.setName(data["name"].toString());script.setSourceCode(data["source"].toString());
        script.setInjectionPoint(QWebEngineScript::DocumentCreation);script.setWorldId(QWebEngineScript::MainWorld);
        script.setRunsOnSubFrames(false);browser->profile->scripts()->insert(script);
    }
    else if(command=="evaluate" && page) {
        auto token=QUuid::createUuid().toString(QUuid::WithoutBraces);
        browser->evaluations[token]={page->number,data["id"].toString()};
        auto prefix=QString("relay-eval:")+token+":";
        auto quoted=QJsonDocument(QJsonArray{prefix}).toJson(QJsonDocument::Compact);quoted=quoted.mid(1,quoted.size()-2);
        page->runJavaScript("Promise.resolve().then(()=>{"+data["source"].toString()+"}).then(value=>console.log("+quoted+"+JSON.stringify({value})),e=>console.log("+quoted+"+JSON.stringify({error:String(e)})))");
    }
    else if(command=="cancelEvaluation") {
        for(auto it=browser->evaluations.begin();it!=browser->evaluations.end();) {
            if(it->second==data["id"].toString())it=browser->evaluations.erase(it);else ++it;
        }
    }
    else if(command=="permission") {
        auto id=data["id"].toString();auto it=browser->permissions.find(id);
        if(it!=browser->permissions.end()){if(data["allow"].toBool())it->grant();else it->deny();browser->permissions.erase(it);}
    }
    else if(command=="resetNotificationPermissions") {
        for(auto permission:browser->profile->listPermissionsForPermissionType(QWebEnginePermission::PermissionType::Notifications)) permission.reset();
    }
    else if(command=="notification") {
        auto it=browser->notifications.find(data["id"].toString().toStdString());
        if(it!=browser->notifications.end()){if(data["click"].toBool())it->second->click();it->second->close();browser->notifications.erase(it);}
    }
    else if(command=="close" && page && page->number) {if(auto widget=browser->views.value(page->number))widget->close();}
    else if(command=="download") {
        auto id=data["id"].toString();auto request=browser->downloads.value(id);if(!request)return;
        auto action=data["action"].toString();
        if(action=="accept") {QFileInfo file(data["path"].toString());request->setDownloadDirectory(file.path());request->setDownloadFileName(file.fileName());request->accept();}
        else if(action=="cancel")request->cancel();
        else if(action=="resume")request->resume();
        else if(action=="pause")request->pause();
        else if(action=="release"){browser->downloads.remove(id);request->deleteLater();}
    }
}
__attribute__((visibility("default"))) char* relay_chromium_processes() {
    QJsonArray rows;QList<pid_t> queue{getpid()};QSet<pid_t> seen;
    while(!queue.isEmpty() && seen.size()<256) {
        auto pid=queue.takeFirst();if(seen.contains(pid))continue;seen.insert(pid);
        rusage_info_v4 info{};
        if(proc_pid_rusage(pid,RUSAGE_INFO_V4,reinterpret_cast<rusage_info_t*>(&info))==0)
            rows.append(QJsonObject{{"pid",pid},{"start",double(info.ri_proc_start_abstime)},{"memory",double(info.ri_phys_footprint)},{"timeTicks",double(info.ri_user_time+info.ri_system_time)}});
        // Unlike proc_listpids, this convenience API returns a PID count, not bytes.
        pid_t children[256]{};int count=proc_listchildpids(pid,children,sizeof(children));
        for(int i=0;i<std::min(count,256);++i)if(children[i]>0)queue.append(children[i]);
    }
    return strdup(QJsonDocument(rows).toJson(QJsonDocument::Compact).constData());
}
__attribute__((visibility("default"))) void relay_chromium_free(char* data) {free(data);}
}
