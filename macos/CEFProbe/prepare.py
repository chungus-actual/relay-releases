"""Instrument the pinned upstream cefsimple sample. Never edits the shipping app."""
from pathlib import Path
import sys
root=Path(sys.argv[1]); sample=root/'tests/cefsimple'
def edit(name,old,new):
 p=sample/name;s=p.read_text()
 if new and new in s:return
 if not new and old not in s:return
 if old not in s:raise SystemExit('Upstream changed: '+name)
 p.write_text(s.replace(old,new,1))
edit('CMakeLists.txt','  mac/English.lproj/MainMenu.xib\n','')
edit('cefsimple_mac.mm','''  [[NSBundle mainBundle] loadNibNamed:@"MainMenu"
                                owner:NSApp
                      topLevelObjects:nil];''','''  // Relay probe creates native views without an Xcode-compiled nib.''')
edit('simple_app.cc','#include "tests/cefsimple/simple_app.h"','#include "tests/cefsimple/simple_app.h"\nextern CefWindowHandle RelayProbeParent(int index);')
edit('simple_app.cc','''    CefBrowserHost::CreateBrowser(window_info, handler, url, browser_settings,
                                  nullptr, nullptr);''','''    for (int index = 0; index < 2; ++index) {
      window_info.SetAsChild(RelayProbeParent(index), CefRect(0, 0, 500, 600));
      CefRequestContextSettings context_settings;
      auto context = CefRequestContext::CreateContext(context_settings, nullptr);
      CefBrowserHost::CreateBrowser(window_info, handler, url, browser_settings, nullptr, context);
    }''')
edit('simple_handler_mac.mm','#include "tests/cefsimple/simple_handler.h"','''#include "tests/cefsimple/simple_handler.h"

#import <Cocoa/Cocoa.h>
CefWindowHandle RelayProbeParent(int index) {
  static NSWindow* window;
  if (!window) {
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1060, 660)
      styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Relay Chromium probe";
    [window center]; [window makeKeyAndOrderFront:nil];
  }
  NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(20 + index * 520, 20, 500, 600)];
  [window.contentView addSubview:host];
  return (__bridge CefWindowHandle)host;
}
''')
edit('simple_handler.h','  // CefDisplayHandler methods:','''  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level,
                        const CefString& message, const CefString& source, int line) override;
  void ProbeTasks();
  // CefDisplayHandler methods:''')
edit('simple_handler.cc','#include "tests/cefsimple/simple_handler.h"','''#include "tests/cefsimple/simple_handler.h"
#include "include/cef_task_manager.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/base/cef_bind.h"
#include <iostream>
''')
edit('simple_handler.cc','  browser_list_.push_back(browser);','''  browser_list_.push_back(browser);
  browser->GetHost()->SetAudioMuted(browser_list_.size() == 1);
  std::cout << "BROWSER " << browser->GetIdentifier() << " muted=" << browser->GetHost()->IsAudioMuted() << std::endl;
  if (browser_list_.size() == 2) {
    auto first = browser_list_.front();
    auto second = browser_list_.back();
    CHECK(first->GetHost()->IsAudioMuted());
    CHECK(!second->GetHost()->IsAudioMuted());
    CHECK(!first->GetHost()->GetRequestContext()->IsSame(second->GetHost()->GetRequestContext()));
    CHECK(!first->GetHost()->GetRequestContext()->IsSharingWith(second->GetHost()->GetRequestContext()));
    std::cout << "PASS: native NSView embedding, isolated request contexts, browser-level mute" << std::endl;
    CefPostDelayedTask(TID_UI, base::BindOnce(&SimpleHandler::ProbeTasks, this), 5000);
  }''')
p=sample/'simple_handler.cc';s=p.read_text()
if 'void SimpleHandler::ProbeTasks()' not in s:
 s+='''
bool SimpleHandler::OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level,
                                     const CefString& message, const CefString& source, int line) {
  std::cout << "PAGE " << browser->GetIdentifier() << " " << message.ToString() << std::endl;
  return true;
}
void SimpleHandler::ProbeTasks() {
  auto manager = CefTaskManager::GetTaskManager();
  CefTaskManager::TaskIdList ids;
  CHECK(manager && manager->GetTaskIdsList(ids));
  for (auto browser : browser_list_) {
    auto id = manager->GetTaskIdForBrowserId(browser->GetIdentifier());
    CefTaskInfo info;
    CHECK(id >= 0 && manager->GetTaskInfo(id, info));
    std::cout << "TASK browser=" << browser->GetIdentifier() << " task=" << id
              << " cpu=" << info.cpu_usage << " memory=" << info.memory << std::endl;
  }
  std::cout << "PASS: browser task attribution" << std::endl;
  CloseAllBrowsers(true);
}
''';p.write_text(s)

edit('cefsimple_mac.mm', '    CefSettings settings;', '    CefSettings settings;\n    CefString(&settings.root_cache_path) = command_line->GetSwitchValue("cache-path");')
edit('simple_handler.cc', '#include <iostream>', '#include <iostream>\nextern void RelayProbeRemove(CefWindowHandle view);')
edit('simple_handler.cc', '''  // Allow the close. For windowed browsers this will result in the OS close
  // event being sent.
  return false;''', '''  RelayProbeRemove(browser->GetHost()->GetWindowHandle());
  return true;''')
p=sample/'simple_handler_mac.mm';s=p.read_text()
if 'void RelayProbeRemove(' not in s:
 s+='''\nvoid RelayProbeRemove(CefWindowHandle handle) {
  NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(handle);
  [view removeFromSuperview];
}\n''';p.write_text(s)
edit('simple_handler.h', '  void ProbeTasks();', '  void ProbeTasks();\n  CefRefPtr<CefTaskManager> probe_manager_;')
edit('simple_handler.h', '#include "include/cef_client.h"', '#include "include/cef_client.h"\n#include "include/cef_task_manager.h"')
edit('simple_handler.cc', '    CefPostDelayedTask(TID_UI, base::BindOnce(&SimpleHandler::ProbeTasks, this), 5000);', '    probe_manager_ = CefTaskManager::GetTaskManager();\n    CefPostDelayedTask(TID_UI, base::BindOnce(&SimpleHandler::ProbeTasks, this), 8000);')
edit('simple_handler.cc', '    std::cout << "TASK browser="', '    CHECK(info.memory > 0);\n    std::cout << "TASK browser="')
