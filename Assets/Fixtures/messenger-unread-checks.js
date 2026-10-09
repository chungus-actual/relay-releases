// Native DOM regressions shared by WebView2, WebKit, and experimental Chromium.
// The caller supplies the production extractor with document/location parameters.
(read => {
  const failures = [];
  let checks = 0;
  const check = (ok, message) => { checks++; if (!ok) failures.push(message); };
  const page = document.implementation.createHTMLDocument('');
  const base = page.createElement('base');
  page.head.append(base);
  let address;
  const load = (title, html, host = 'www.facebook.com', path = '/messages/') => {
    address = new URL('https://' + host + path);
    base.href = address.href;
    page.title = title;
    page.body.innerHTML = html;
  };
  const reading = () => read(page, address);
  const empty = message => {
    const value = reading();
    check(value.Count === null && !value.Unread, message);
    return value;
  };
  const row = (href, marker = 'aria-label="Unread messages"') =>
    '<div role="row"><a href="' + href + '"><span ' + marker + '></span></a></div>';
  const total = label => '<nav><button aria-label="' + label + '"></button></nav>';
  const announcement = '<nav aria-label="Notifications"><a href="/notifications/"><span aria-label="Unread">Meta Accounts are coming to Facebook. You’ll be updated to yours soon.</span></a></nav>';

  for (const host of ['facebook.com', 'www.facebook.com']) {
    for (const title of ['(28) Facebook', '(28) Messenger', '(28) Messages | Facebook']) {
      load(title, announcement, host);
      const first = empty(host + ' ignores general notification title: ' + title);
      check(JSON.stringify(first) === JSON.stringify(reading()), 'Duplicate notification polling is stable');
      page.title = '(29) Messenger';
      check(JSON.stringify(first) === JSON.stringify(reading()), 'A new Facebook notification does not change the unread key');
    }
  }
  for (const label of ['Messenger, 4 unread notifications', 'Notifications about Messenger, 4 unread messages',
    'Mark 4 messages as unread', 'Messenger announcement, 4 unread', 'Messenger, 4 unread messages and 28 notifications']) {
    load('(28) Messenger', total(label));
    empty('Reject unrelated/action label: ' + label);
  }
  for (const label of ['Messenger, 4 unread messages', 'Chats, 4 unread conversations', 'Messages (4 unread)', '4 unread messages']) {
    load('(28) Messenger', announcement + total(label));
    check(reading().Count === 4, 'Accept explicit message total: ' + label);
  }
  load('(28) Messenger', total('Messenger, 1,234 unread messages'));
  check(reading().Count === 1234, 'Accept grouped message totals');
  load('(28) Messenger', total('Messenger, 1000000 unread messages'));
  empty('Reject out-of-range message totals');

  load('(28) Messenger', announcement + '<nav>' + row('/messages/t/123', 'aria-label="2 unread messages"') + '</nav>');
  const unread = reading();
  check(unread.Count === null && unread.Unread, 'A conversation marker is a dot, not a global total');
  page.body.insertAdjacentHTML('beforeend', row('/messages/t/123'));
  check(JSON.stringify(unread) === JSON.stringify(reading()), 'Duplicate representations of a thread do not create new activity');
  page.body.innerHTML = announcement + row('/messages/t/456') + row('/messages/t/123');
  const multiple = reading();
  page.body.innerHTML = row('/messages/t/123') + announcement + row('/messages/t/456');
  check(multiple.Key === reading().Key, 'Row order does not change unread identity');
  check(multiple.Key !== unread.Key, 'A new conversation changes the unread key');
  page.body.innerHTML = announcement;
  empty('Reading the last chat clears unread while the Facebook announcement and title remain');

  load('(28) Messenger', announcement + total('Messenger, 0 unread messages') + row('/messages/t/stale'));
  check(reading().Count === 0 && !reading().Unread, 'Explicit zero overrides a stale virtualized row and Facebook title');
  page.querySelector('button').remove();
  page.querySelector('[role="row"]').remove();
  empty('Removing a zero badge cannot resurrect the Facebook title count');

  for (const href of ['/notifications/', '/t/not-a-facebook-thread', 'https://example.com/messages/t/123',
    '/redirect?next=/messages/t/123', '/messages/t/']) {
    load('(28) Messenger', row(href));
    empty('Reject non-conversation link: ' + href);
  }
  for (const href of ['/messages/t/123', '/messages/e2ee/t/456']) {
    load('(28) Messenger', row(href, 'data-testid="mwthreadlist_unread_indicator"'));
    check(reading().Count === null && reading().Unread, 'Accept unread conversation: ' + href);
  }
  load('(28) Messenger', row('/messages/t/123', 'aria-label="Mark as unread"'));
  empty('Mark as unread action is not unread evidence');
  for (const host of ['messenger.com', 'www.messenger.com']) {
    load('(12+) Messenger', '', host, '/');
    check(reading().Count === 12, 'Dedicated Messenger title remains supported: ' + host);
    load('Messenger', row('/t/123'), host, '/');
    check(reading().Count === null && reading().Unread, 'Dedicated Messenger thread remains supported: ' + host);
  }
  return { checks, failures };
})
