(() => {
  const platform = document.body.dataset.platform;
  const storageKey = `torchat.maquette.${platform}.v3`;
  const app = document.getElementById('app');
  const overlay = document.getElementById('overlay-root');

  const seed = {
    screen: 'splash',
    destination: 'chats',
    routeStack: [{ kind: 'list' }],
    modal: null,
    theme: 'dark',
    profile: {
      nickname: 'Maja',
      fingerprint: 'A1C3-9F20-72D4',
      inviteCode: '48273190',
      inviteExpires: 60,
    },
    transport: {
      status: 'connecting',
      onion: 'http://gd6xcrek7ncoujoz72g4icexj45b4atzbk5gjhqm06thngmgcbci4cqd.onion',
      socks: '127.0.0.1:19050',
      latency: '28 ms',
      queue: [],
    },
    search: {
      chats: '',
      contacts: '',
      inbox: '',
    },
    contacts: [
      {
        id: 'alice',
        name: 'Alice',
        initial: 'A',
        fingerprint: 'A1C3-9F20',
        verified: true,
        status: 'online',
        note: 'Kontakt testowy',
      },
      {
        id: 'bob',
        name: 'Bob',
        initial: 'B',
        fingerprint: 'B7D2-44A1',
        verified: false,
        status: 'offline',
        note: 'Kontakt testowy',
      },
    ],
    conversations: [
      {
        id: 'alice',
        name: 'Alice',
        initial: 'A',
        unread: 2,
        preview: 'Możemy przetestować połączenie?',
        time: '10:42',
        fingerprint: 'A1C3-9F20',
        verified: true,
        messages: [
          { from: 'Alice', body: 'Hej! Działa już Tor?', time: '10:40' },
          { from: 'Maja', body: 'Tak, jestem online.', time: '10:41' },
          { from: 'Alice', body: 'Możemy przetestować połączenie?', time: '10:42' },
        ],
      },
      {
        id: 'bob',
        name: 'Bob',
        initial: 'B',
        unread: 0,
        preview: 'Zaproszenie zaakceptowane',
        time: '09:18',
        fingerprint: 'B7D2-44A1',
        verified: false,
        messages: [
          { from: 'Bob', body: 'Zaproszenie zaakceptowane', time: '09:18' },
        ],
      },
    ],
    inbox: [
      {
        id: 'req1',
        name: 'Charlie',
        initial: 'C',
        code: '71904258',
        kind: 'received',
        status: 'pending',
        note: 'Nowe zaproszenie',
      },
      {
        id: 'req2',
        name: 'Delta',
        initial: 'D',
        code: '99550011',
        kind: 'sent',
        status: 'pending',
        note: 'Oczekuje na akceptację',
      },
    ],
  };

  const icons = {
    message: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21 15a2 2 0 0 1-2 2H8l-5 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linejoin="round"/></svg>',
    users: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16 21v-2a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v2" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/><circle cx="9" cy="7" r="3" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M20 21v-2a3.5 3.5 0 0 0-2.5-3.36" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/><path d="M16 4.1a3 3 0 0 1 0 5.8" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    inbox: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 4h18v10h-5l-2 3H10l-2-3H3z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linejoin="round"/><path d="M3 14l3 6h12l3-6" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linejoin="round"/></svg>',
    user: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="3.5" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M4 21v-1.5A5.5 5.5 0 0 1 9.5 14h5A5.5 5.5 0 0 1 20 19.5V21" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    search: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6.5" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M16 16l4 4" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    plus: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    send: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M22 3L11 14" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/><path d="M22 3l-7 18-4-8-8-4z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linejoin="round"/></svg>',
    info: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M12 10.2v6M12 7h.01" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 18l-6-6 6-6" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    qr: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linejoin="round"/><path d="M15 14h1v1h-1zM18 14h2v2h-2zM15 17h2v2h-2zM18 18h2v2h-2z" fill="currentColor"/><path d="M12 12h2v2h-2zM14 16h2v2h-2zM16 12h2v2h-2zM19 12h1v1h-1z" fill="currentColor"/></svg>',
    copy: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="9" width="10" height="10" rx="1" fill="none" stroke="currentColor" stroke-width="1.75"/><rect x="5" y="5" width="10" height="10" rx="1" fill="none" stroke="currentColor" stroke-width="1.75"/></svg>',
    check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 6l-11 11-5-5" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    x: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    shield: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linejoin="round"/><path d="M9.5 12l1.8 1.8L15 10" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    refresh: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 11a8 8 0 1 0 1 4" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/><path d="M20 4v7h-7" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    moon: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14.5 3a8.5 8.5 0 1 0 6.5 13.8A9.5 9.5 0 0 1 14.5 3z" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linejoin="round"/></svg>',
    sun: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.5" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M12 2v3M12 19v3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M2 12h3M19 12h3M4.9 19.1l2.1-2.1M17 7l2.1-2.1" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    onion: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4c4.2 0 7.5 3.3 7.5 7.5S16.2 19 12 19s-7.5-3.3-7.5-7.5S7.8 4 12 4z" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M12 7v10M8.5 9.5l7 5M15.5 9.5l-7 5" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg>',
    dots: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="5" r="1.5" fill="currentColor"/><circle cx="12" cy="12" r="1.5" fill="currentColor"/><circle cx="12" cy="19" r="1.5" fill="currentColor"/></svg>',
    settings: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M19.4 13.5l1.2.9-1.8 3.1-1.4-.6a7.3 7.3 0 0 1-2.2 1.3l-.2 1.5h-3.6l-.2-1.5a7.3 7.3 0 0 1-2.2-1.3l-1.4.6-1.8-3.1 1.2-.9a7 7 0 0 1 0-2.6l-1.2-.9 1.8-3.1 1.4.6a7.3 7.3 0 0 1 2.2-1.3l.2-1.5h3.6l.2 1.5a7.3 7.3 0 0 1 2.2 1.3l1.4-.6 1.8 3.1-1.2.9a7 7 0 0 1 0 2.6z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>',
  };

  const clone = (value) => JSON.parse(JSON.stringify(value));
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));

  function iconPack() {
    return {
      iconClose: icons.x,
      iconCopy: icons.copy,
      iconSend: icons.send,
      iconQr: icons.qr,
      iconTheme: state.theme === 'dark' ? icons.sun : icons.moon,
      iconOnion: icons.onion,
      iconDelete: icons.x,
      iconDots: icons.dots,
      iconMessage: icons.message,
      iconRefresh: icons.refresh,
      iconEmpty: icons.onion,
      iconUser: icons.user,
      settingsIcon: icons.settings,
    };
  }

  function normalizeState(raw) {
    if (!raw || typeof raw !== 'object') return clone(seed);
    const next = clone(seed);
    Object.assign(next, raw);
    next.profile = { ...clone(seed.profile), ...(raw.profile || {}) };
    next.transport = { ...clone(seed.transport), ...(raw.transport || {}) };
    next.search = { ...clone(seed.search), ...(raw.search || {}) };
    next.contacts = Array.isArray(raw.contacts) ? raw.contacts : clone(seed.contacts);
    next.conversations = Array.isArray(raw.conversations) ? raw.conversations : clone(seed.conversations);
    next.inbox = Array.isArray(raw.inbox) ? raw.inbox : clone(seed.inbox);
    next.routeStack = Array.isArray(raw.routeStack) && raw.routeStack.length ? raw.routeStack : [{ kind: 'list' }];
    next.modal = raw.modal ?? null;
    next.destination = raw.destination || 'chats';
    next.screen = raw.screen || 'splash';
    next.theme = raw.theme === 'light' ? 'light' : 'dark';
    return next;
  }

  let state = normalizeState(JSON.parse(localStorage.getItem(storageKey) || 'null'));
  let pendingFocus = null;

  function isCompactLayout() {
    return platform === 'mobile' || window.matchMedia('(max-width: 899px)').matches;
  }

  function save() {
    const persisted = {
      ...state,
      modal: null,
      screen: state.screen === 'main' ? 'main' : 'splash',
    };
    localStorage.setItem(storageKey, JSON.stringify(persisted));
  }

  function route() {
    return state.routeStack[state.routeStack.length - 1] || { kind: 'list' };
  }

  function isRoot() {
    return route().kind === 'list';
  }

  function markFocus(field) {
    pendingFocus = field;
  }

  function renderTemplate(id, values = {}) {
    const raw = document.getElementById(`tpl-${id}`).innerHTML;
    const merged = { ...iconPack(), ...values };
    return raw.replace(/\{\{([\w-]+)\}\}/g, (_, key) => merged[key] ?? '');
  }

  function copyText(text) {
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text);
    }
  }

  function routeTitle(kind) {
    if (kind === 'conversation') return 'Rozmowa';
    if (kind === 'contact') return 'Kontakt';
    if (kind === 'invite') return 'Zaproszenie';
    if (kind === 'new-contact') return 'Dodaj kontakt';
    if (kind === 'account') return 'Konto';
    if (kind === 'settings') return 'Ustawienia';
    if (kind === 'tor') return 'Tor';
    return state.destination === 'contacts' ? 'Kontakty' : state.destination === 'inbox' ? 'Inbox' : 'Czaty';
  }

  function routeSubtitle(current) {
    if (current.kind === 'conversation') {
      const item = state.conversations.find((entry) => entry.id === current.id);
      return item?.verified ? 'Zweryfikowany kontakt' : 'Fingerprint oczekuje';
    }
    if (current.kind === 'contact') {
      const item = state.contacts.find((entry) => entry.id === current.id);
      return item?.verified ? 'Kontakt zweryfikowany' : 'Kontakt niezweryfikowany';
    }
    if (current.kind === 'invite') return 'Akceptacja lub odrzucenie zaproszenia';
    if (current.kind === 'new-contact') return 'Dodaj kontakt przez 8-cyfrowy kod';
    if (current.kind === 'account') return 'Lokalny profil i ustawienia';
    if (current.kind === 'settings') return 'Preferencje aplikacji i dane lokalne';
    if (current.kind === 'tor') return 'Stan połączenia onion i kolejka wysyłki';
    return state.destination === 'contacts' ? 'Kontakty zapisane lokalnie' : state.destination === 'inbox' ? 'Zaproszenia i odpowiedzi' : 'Rozmowy dostępne po połączeniu';
  }

  function currentConnectionLabel() {
    if (state.transport.status === 'connected') return 'Tor połączony';
    if (state.transport.status === 'error') return 'Tor offline';
    return 'Łączenie Tor';
  }

  function currentConnectionClass() {
    if (state.transport.status === 'connected') return 'ok';
    if (state.transport.status === 'error') return 'bad';
    return 'warn';
  }

  function currentConnectionIcon() {
    if (state.transport.status === 'connected') return icons.shield;
    if (state.transport.status === 'error') return icons.x;
    return icons.onion;
  }

  function initials() {
    return esc((state.profile.nickname || 'M')[0].toUpperCase());
  }

  function now() {
    return new Date().toLocaleTimeString('pl-PL', { hour: '2-digit', minute: '2-digit' });
  }

  function filteredChats() {
    const query = state.search.chats.trim().toLowerCase();
    return state.conversations.filter((item) => !query || [item.name, item.preview, item.fingerprint].some((value) => String(value).toLowerCase().includes(query)));
  }

  function filteredContacts() {
    const query = state.search.contacts.trim().toLowerCase();
    return state.contacts.filter((item) => !query || [item.name, item.note, item.fingerprint].some((value) => String(value).toLowerCase().includes(query)));
  }

  function filteredInbox() {
    const query = state.search.inbox.trim().toLowerCase();
    return state.inbox.filter((item) => !query || [item.name, item.code, item.note].some((value) => String(value).toLowerCase().includes(query)));
  }

  function listMeta() {
    const profileAction = isCompactLayout()
      ? [{ action: 'open-account', icon: icons.user, label: 'Konto' }]
      : [];
    if (state.destination === 'contacts') {
      return {
        eyebrow: 'Baza kontaktów',
        title: 'Kontakty',
        subtitle: 'Wyszukuj po nicku lub fingerprintcie',
        actions: [
          { action: 'open-new-contact', icon: icons.plus, label: 'Dodaj kontakt' },
          { action: 'open-qr', icon: icons.qr, label: 'Mój kod' },
          ...profileAction,
        ],
        placeholder: 'Szukaj kontaktów…',
      };
    }
    if (state.destination === 'inbox') {
      return {
        eyebrow: 'Obsługa zaproszeń',
        title: 'Inbox',
        subtitle: 'Zaproszenia przychodzące i wysłane',
        actions: [
          { action: 'open-qr', icon: icons.qr, label: 'Mój kod' },
          ...profileAction,
        ],
        placeholder: 'Szukaj zaproszeń…',
      };
    }
    return {
      eyebrow: 'Rozmowy bieżące',
      title: 'Czaty',
      subtitle: 'Rozmowy i stan dostarczenia',
      actions: [
        { action: 'open-new-contact', icon: icons.plus, label: 'Dodaj kontakt' },
        { action: 'open-qr', icon: icons.qr, label: 'Mój kod' },
        ...profileAction,
      ],
      placeholder: 'Szukaj rozmów…',
    };
  }

  function listItems() {
    if (state.destination === 'contacts') {
      const items = filteredContacts().map((item) => renderTemplate('contact-row', {
        id: item.id,
        initial: esc(item.initial),
        name: esc(item.name),
        note: esc(item.note || 'Kontakt lokalny'),
        fingerprint: esc(item.fingerprint),
        verifiedClass: item.verified ? 'ok' : 'warn',
        verifiedLabel: item.verified ? 'Zweryfikowany' : 'Wymaga weryfikacji',
      })).join('');
      return items || renderTemplate('empty', {
        title: 'Brak kontaktów',
        body: 'Użyj 8-cyfrowego kodu, aby dodać osobę.',
      });
    }
    if (state.destination === 'inbox') {
      const items = filteredInbox().map((item) => renderTemplate('inbox-row', {
        id: item.id,
        initial: esc(item.initial),
        name: esc(item.name),
        code: esc(item.code),
        note: esc(item.note),
        kind: item.kind,
        statusLabel: item.kind === 'received' ? 'Otrzymane' : 'Wysłane',
        statusClass: item.kind === 'received' ? 'ok' : 'warn',
      })).join('');
      return items || renderTemplate('empty', {
        title: 'Inbox pusty',
        body: 'Nowe zaproszenia pojawią się tutaj.',
      });
    }
    const selected = route().kind === 'conversation' ? route().id : null;
    const items = filteredChats().map((item) => renderTemplate('chat-row', {
      id: item.id,
      initial: esc(item.initial),
      name: esc(item.name),
      preview: esc(item.preview),
      time: esc(item.time),
      unread: item.unread ? `<span class="badge">${item.unread}</span>` : '',
      active: item.id === selected ? 'active' : '',
    })).join('');
    return items || renderTemplate('empty', {
      title: 'Brak rozmów',
      body: 'Po dodaniu kontaktu zobaczysz tutaj czat.',
    });
  }

  function messageRows(messages) {
    return messages.map((message) => renderTemplate('message-row', {
      body: esc(message.body),
      time: esc(message.time),
      mine: message.from === state.profile.nickname ? 'mine' : '',
    })).join('');
  }

  function conversationBody(current) {
    const conversation = state.conversations.find((item) => item.id === current.id);
    if (!conversation) return renderTemplate('empty', { title: 'Brak rozmowy', body: 'Ta rozmowa nie istnieje.' });
    const queue = state.transport.queue.includes(conversation.id)
      ? `<div class="queue-note">${icons.refresh}<div><b>Wiadomość w kolejce</b><p>Oczekuje na połączenie Tor.</p></div></div>`
      : '';
    return `
      <div class="chat-flow">
        <div class="messages">
          ${messageRows(conversation.messages)}
          ${queue}
        </div>
        <form class="composer" data-action="send-message">
          <input data-field="message" class="field" placeholder="Napisz wiadomość..." autocomplete="off">
          <button class="primary icon-button" type="submit">${icons.send}</button>
        </form>
      </div>
    `;
  }

  function contactBody(current) {
    const contact = state.contacts.find((item) => item.id === current.id);
    if (!contact) return renderTemplate('empty', { title: 'Brak kontaktu', body: 'Nie znaleziono tego kontaktu.' });
    return renderTemplate('contact-detail', {
      initial: esc(contact.initial),
      name: esc(contact.name),
      note: esc(contact.note || 'Kontakt lokalny'),
      fingerprint: esc(contact.fingerprint),
      statusLabel: contact.verified ? 'Fingerprint zweryfikowany' : 'Fingerprint niezweryfikowany',
      statusClass: contact.verified ? 'ok' : 'warn',
      contactId: esc(contact.id),
    });
  }

  function inviteBody(current) {
    const invite = state.inbox.find((item) => item.id === current.id);
    if (!invite) return renderTemplate('empty', { title: 'Brak zaproszenia', body: 'To zaproszenie nie jest już dostępne.' });
    return renderTemplate('invite-detail', {
      initial: esc(invite.initial),
      name: esc(invite.name),
      code: esc(invite.code),
      note: esc(invite.note),
      kindLabel: invite.kind === 'received' ? 'Zaproszenie otrzymane' : 'Zaproszenie wysłane',
      statusClass: invite.kind === 'received' ? 'ok' : 'muted',
      actions: invite.kind === 'received'
        ? `<button class="primary" data-action="accept-invite" data-id="${esc(invite.id)}">${icons.check} Akceptuj</button><button class="ghost danger" data-action="reject-invite" data-id="${esc(invite.id)}">${icons.x} Odrzuć</button>`
        : `<button class="ghost danger" data-action="cancel-invite" data-id="${esc(invite.id)}">${icons.x} Anuluj wysyłkę</button>`,
    });
  }

  function newContactBody() {
    return renderTemplate('new-contact', {
      inviteCode: '',
      helper: 'Wpisz 8 cyfr. Kod jest jednorazowy.',
    });
  }

  function accountBody() {
    return renderTemplate('account-detail', {
      nickname: esc(state.profile.nickname),
      fingerprint: esc(state.profile.fingerprint),
      themeLabel: state.theme === 'dark' ? 'Ciemny' : 'Jasny',
      torLabel: currentConnectionLabel(),
      torClass: currentConnectionClass(),
    });
  }

  function settingsBody() {
    return renderTemplate('settings-detail', {
      nickname: esc(state.profile.nickname),
      themeLabel: state.theme === 'dark' ? 'Ciemny' : 'Jasny',
      torLabel: currentConnectionLabel(),
    });
  }

  function torBody() {
    return renderTemplate('tor-detail', {
      onion: esc(state.transport.onion),
      socks: esc(state.transport.socks),
      latency: esc(state.transport.latency),
      queueCount: state.transport.queue.length,
      torLabel: currentConnectionLabel(),
      torClass: currentConnectionClass(),
      actionLabel: state.transport.status === 'connected' ? 'Symuluj rozłączenie' : 'Ponów połączenie',
    });
  }

  function inspectorBody() {
    const current = route();
    if (current.kind === 'conversation') {
      const conversation = state.conversations.find((item) => item.id === current.id);
      if (!conversation) return '';
      return renderTemplate('inspector', {
        initial: esc(conversation.initial),
        title: esc(conversation.name),
        subtitle: conversation.verified ? 'Zweryfikowany kontakt' : 'Fingerprint oczekuje',
        fingerprint: esc(conversation.fingerprint),
        note: conversation.unread ? esc(`${conversation.unread} nieprzeczytane`) : 'Brak nieprzeczytanych',
      });
    }
    return '';
  }

  function detailView() {
    const current = route();
    if (current.kind === 'conversation') {
      const conversation = state.conversations.find((item) => item.id === current.id);
    return renderTemplate('detail-shell', {
      back: icons.back,
      eyebrow: 'Rozmowa',
      title: esc(conversation?.name || 'Rozmowa'),
      subtitle: conversation?.verified ? 'Zweryfikowany kontakt' : 'Fingerprint oczekuje',
      actions: `<button class="ghost" data-action="open-actions">${icons.dots}</button><button class="ghost" data-action="open-contact" data-id="${esc(current.id)}">${icons.user}</button>`,
        body: conversationBody(current),
      });
    }
    if (current.kind === 'contact') {
      const contact = state.contacts.find((item) => item.id === current.id);
    return renderTemplate('detail-shell', {
      back: icons.back,
      eyebrow: 'Kontakt',
      title: esc(contact?.name || 'Kontakt'),
      subtitle: contact?.verified ? 'Zweryfikowany kontakt' : 'Kontakt niezweryfikowany',
      actions: `<button class="ghost" data-action="open-actions">${icons.dots}</button><button class="ghost" data-action="open-chat" data-id="${esc(current.id)}">${icons.message}</button>`,
        body: contactBody(current),
      });
    }
    if (current.kind === 'invite') {
    return renderTemplate('detail-shell', {
      back: icons.back,
      eyebrow: 'Zaproszenie',
      title: 'Zaproszenie',
      subtitle: routeSubtitle(current),
      actions: `<button class="ghost" data-action="open-actions">${icons.dots}</button>`,
        body: inviteBody(current),
      });
    }
    if (current.kind === 'new-contact') {
    return renderTemplate('detail-shell', {
      back: icons.back,
      eyebrow: 'Nowy kontakt',
      title: 'Dodaj kontakt',
      subtitle: '8-cyfrowy kod zaproszenia',
      actions: `<button class="ghost" data-action="open-qr">${icons.qr}</button>`,
        body: newContactBody(),
      });
    }
    if (current.kind === 'account') {
    return renderTemplate('detail-shell', {
      back: icons.back,
      eyebrow: 'Profil',
      title: 'Konto',
      subtitle: 'Nickname, kod i ustawienia lokalne',
      actions: `<button class="ghost" data-action="open-qr">${icons.qr}</button><button class="ghost" data-action="open-settings">${icons.settings}</button><button class="ghost" data-action="toggle-theme">${state.theme === 'dark' ? icons.sun : icons.moon}</button>`,
        body: accountBody(),
      });
    }
    if (current.kind === 'settings') {
      return renderTemplate('detail-shell', {
        back: icons.back,
        eyebrow: 'Konfiguracja',
        title: 'Ustawienia',
        subtitle: 'Preferencje aplikacji i dane lokalne',
        actions: `<button class="ghost" data-action="toggle-theme">${state.theme === 'dark' ? icons.sun : icons.moon}</button>`,
        body: settingsBody(),
      });
    }
    if (current.kind === 'tor') {
    return renderTemplate('detail-shell', {
      back: icons.back,
      eyebrow: 'Tor',
      title: 'Tor',
      subtitle: 'Status połączenia onion',
      actions: `<button class="ghost" data-action="toggle-tor">${icons.refresh}</button>`,
        body: torBody(),
      });
    }
    return renderTemplate('empty', { title: 'Wybierz widok', body: 'Kliknij rozmowę, kontakt lub zaproszenie.' });
  }

  function mobileHeader() {
    return `
      <button class="tor-strip ${currentConnectionClass()}" data-action="open-tor" title="${esc(currentConnectionLabel())}" aria-label="${esc(currentConnectionLabel())}">
        <span>${esc(currentConnectionLabel())}</span>
      </button>
    `;
  }

  function mobileDock() {
    if (!isRoot()) return '';
    return renderTemplate('dock', {
      chatsClass: state.destination === 'chats' ? 'active' : '',
      contactsClass: state.destination === 'contacts' ? 'active' : '',
      inboxClass: state.destination === 'inbox' ? 'active' : '',
      chatsIcon: icons.message,
      contactsIcon: icons.users,
      inboxIcon: icons.inbox,
      chatsLabel: 'Czaty',
      contactsLabel: 'Kontakty',
      inboxLabel: 'Inbox',
      inboxBadge: state.inbox.length ? `<span class="badge">${state.inbox.length}</span>` : '',
    });
  }

  function desktopRail() {
    return renderTemplate('rail', {
      initial: initials(),
      nickname: esc(state.profile.nickname),
      chatsClass: state.destination === 'chats' ? 'active' : '',
      contactsClass: state.destination === 'contacts' ? 'active' : '',
      inboxClass: state.destination === 'inbox' ? 'active' : '',
      chatsIcon: icons.message,
      contactsIcon: icons.users,
      inboxIcon: icons.inbox,
      inboxBadge: state.inbox.length ? `<span class="badge">${state.inbox.length}</span>` : '',
      settingsIcon: icons.settings,
    });
  }

  function desktopStatus() {
    return renderTemplate('desktop-status', {
      torClass: currentConnectionClass(),
      torLabel: currentConnectionLabel(),
      latency: state.transport.status === 'connected' ? esc(state.transport.latency) : '— ms',
    });
  }

  function listView() {
    const meta = listMeta();
    const searchValue = state.search[state.destination] || '';
    return renderTemplate('list-shell', {
      title: meta.title,
      eyebrow: meta.eyebrow,
      subtitle: meta.subtitle,
      actions: meta.actions.map((item) => `<button class="icon" data-action="${esc(item.action)}" title="${esc(item.label)}" aria-label="${esc(item.label)}">${item.icon}</button>`).join(''),
      search: `<div class="search-wrap">${icons.search}<input data-field="search" class="field search" value="${esc(searchValue)}" placeholder="${esc(meta.placeholder)}" autocomplete="off"></div>`,
      items: listItems(),
    });
  }

  function desktopMain() {
    const current = route();
    if (current.kind === 'list') {
      return renderTemplate('empty', {
        title: state.destination === 'chats' ? 'Wybierz rozmowę' : state.destination === 'contacts' ? 'Wybierz kontakt' : 'Wybierz zaproszenie',
        body: 'Widok szczegółowy pojawi się tutaj.',
      });
    }
    return detailView();
  }

  function renderModal() {
    if (!state.modal) {
      overlay.innerHTML = '';
      return;
    }
    if (state.modal.kind === 'qr') {
      const cells = Array.from({ length: 121 }, (_, index) => `<i class="${(index * 5 + Number(state.profile.inviteCode.slice(-2))) % 7 === 0 ? 'off' : ''}"></i>`).join('');
      overlay.innerHTML = renderTemplate('modal-qr', {
        code: esc(state.profile.inviteCode),
        expires: state.profile.inviteExpires,
        qr: cells,
        title: 'Twój kod zaproszenia',
        subtitle: 'QR zawsze ma białe tło',
      });
      return;
    }
    if (state.modal.kind === 'new-contact') {
      overlay.innerHTML = renderTemplate('modal-new-contact', {
        title: 'Dodaj kontakt',
        subtitle: 'Wpisz 8-cyfrowy kod',
        helper: 'Kod działa jednorazowo i nie jest zapisywany w widoku.',
      });
      pendingFocus = 'invite-code';
      return;
    }
    if (state.modal.kind === 'confirm') {
      overlay.innerHTML = renderTemplate('modal-confirm', {
        title: esc(state.modal.title),
        body: esc(state.modal.body),
        confirmAction: esc(state.modal.confirmAction),
        confirmLabel: esc(state.modal.confirmLabel || 'Potwierdź'),
        dangerClass: state.modal.danger ? 'danger' : '',
      });
      return;
    }
    if (state.modal.kind === 'error') {
      overlay.innerHTML = renderTemplate('modal-error', {
        title: esc(state.modal.title || 'Błąd'),
        body: esc(state.modal.body || 'Nieoczekiwany problem.'),
      });
      return;
    }
    overlay.innerHTML = renderTemplate('modal-actions', {
      title: esc(state.modal.title || 'Akcje'),
      body: esc(state.modal.body || 'Wybierz akcję.'),
      actions: state.modal.actions || '',
    });
  }

  function render() {
    document.body.dataset.theme = state.theme;
    if (state.screen !== 'main') {
      if (state.screen === 'splash') {
        app.innerHTML = renderTemplate('splash', {
          brand: icons.onion,
        });
      } else if (state.screen === 'tor') {
        app.innerHTML = renderTemplate('tor-onboarding', {
          brand: icons.onion,
          title: 'Bezpieczne połączenie Tor',
          subtitle: 'Uwierzytelnianie przez onion',
          progress: state.transport.status === 'connected' ? 100 : 58,
          label: currentConnectionLabel(),
          retry: state.transport.status === 'error' ? '<button class="primary" data-action="retry-tor">Spróbuj ponownie</button>' : '',
        });
      } else {
        app.innerHTML = renderTemplate('nickname', {
          brand: icons.user,
          nickname: esc(state.profile.nickname),
        });
      }
      renderModal();
      return;
    }

    if (isCompactLayout()) {
      app.innerHTML = renderTemplate('mobile-shell', {
        topbar: mobileHeader(),
        body: isRoot() ? listView() : detailView(),
        dock: mobileDock(),
      });
    } else {
      const inspector = inspectorBody();
      app.innerHTML = renderTemplate('desktop-shell', {
        desktopStatus: desktopStatus(),
        rail: desktopRail(),
        list: listView(),
        body: desktopMain(),
        inspector,
        desktopMode: inspector ? 'with-inspector' : 'no-inspector',
      });
    }

    renderModal();

    if (pendingFocus) {
      const target = document.querySelector(`[data-field="${pendingFocus}"]`);
      if (target) {
        target.focus();
        if ('selectionStart' in target && typeof target.value === 'string') {
          const length = target.value.length;
          try {
            target.setSelectionRange(length, length);
          } catch {
            // No-op.
          }
        }
      }
      pendingFocus = null;
    }
  }

  function openDestination(destination, routeItem = null) {
    state.destination = destination;
    state.routeStack = [{ kind: 'list' }];
    if (routeItem) state.routeStack.push(routeItem);
    state.modal = null;
    save();
    render();
  }

  function openConversation(id) {
    const conversation = state.conversations.find((item) => item.id === id);
    if (!conversation) return;
    conversation.unread = 0;
    openDestination('chats', { kind: 'conversation', id });
  }

  function openContact(id) {
    openDestination('contacts', { kind: 'contact', id });
  }

  function openInvite(id) {
    openDestination('inbox', { kind: 'invite', id });
  }

  function openAccount() {
    state.routeStack = [{ kind: 'list' }, { kind: 'account' }];
    state.modal = null;
    save();
    render();
  }

  function openSettings() {
    state.routeStack = [{ kind: 'list' }, { kind: 'settings' }];
    state.modal = null;
    save();
    render();
  }

  function openTor() {
    state.routeStack = [{ kind: 'list' }, { kind: 'tor' }];
    state.modal = null;
    save();
    render();
  }

  function openNewContact() {
    openModal({
      kind: 'new-contact',
    });
  }

  function goBack() {
    if (state.modal) {
      state.modal = null;
      save();
      render();
      return;
    }
    if (state.routeStack.length > 1) {
      state.routeStack.pop();
      save();
      render();
      return;
    }
  }

  function openQr() {
    openModal({
      kind: 'qr',
    });
  }

  function openActions(kind) {
    if (kind === 'conversation') {
      state.modal = {
        kind: 'actions',
        title: 'Akcje rozmowy',
        body: 'Drobne akcje można wykonać w modalu.',
        actions: `
          <button class="ghost" data-action="open-contact-from-route">${icons.user} Kontakt</button>
          <button class="ghost" data-action="open-qr">${icons.qr} QR</button>
          <button class="ghost danger" data-action="open-confirm" data-confirm="disconnect">${icons.refresh} Symuluj offline</button>
        `,
      };
      save();
      render();
      return;
    }
    state.modal = {
      kind: 'actions',
      title: 'Akcje',
      body: 'Szybkie akcje dla bieżącego widoku.',
      actions: `
        <button class="ghost" data-action="open-qr">${icons.qr} QR</button>
        <button class="ghost danger" data-action="open-confirm" data-confirm="reset">${icons.x} Reset demo</button>
      `,
    };
    save();
    render();
  }

  function openModal(modal) {
    state.modal = modal;
    save();
    render();
  }

  function resolveConfirm(kind) {
    if (kind === 'disconnect') {
      state.transport.status = state.transport.status === 'connected' ? 'error' : 'connected';
      if (state.transport.status === 'connected') state.transport.queue = [];
      state.modal = null;
      save();
      render();
      return;
    }
    if (kind === 'reset') {
      localStorage.removeItem(storageKey);
      state = normalizeState(null);
      save();
      render();
      return;
    }
    if (kind === 'reject-invite' || kind === 'cancel-invite') {
      const current = route();
      const id = current.kind === 'invite' ? current.id : null;
      if (id) state.inbox = state.inbox.filter((item) => item.id !== id);
      state.modal = null;
      save();
      render();
      return;
    }
    state.modal = null;
    save();
    render();
  }

  function acceptInvite(id) {
    const invite = state.inbox.find((item) => item.id === id);
    if (!invite) return;
    const contactId = `contact-${invite.id}`;
    state.contacts.push({
      id: contactId,
      name: invite.name,
      initial: invite.initial,
      fingerprint: `${invite.code.slice(0, 4)}-${invite.code.slice(4)}`,
      verified: false,
      status: 'online',
      note: 'Dodany przez zaproszenie',
    });
    state.conversations.push({
      id: contactId,
      name: invite.name,
      initial: invite.initial,
      unread: 0,
      preview: 'Nowy kontakt',
      time: 'teraz',
      fingerprint: `${invite.code.slice(0, 4)}-${invite.code.slice(4)}`,
      verified: false,
      messages: [],
    });
    state.inbox = state.inbox.filter((item) => item.id !== id);
    state.modal = null;
    save();
    openDestination('chats', { kind: 'conversation', id: contactId });
  }

  function rejectInvite(id) {
    openModal({
      kind: 'confirm',
      title: 'Odrzucić zaproszenie?',
      body: 'Ta operacja usunie zaproszenie z inboxa.',
      confirmAction: 'reject-invite',
      confirmLabel: 'Odrzuć',
      danger: true,
      id,
    });
  }

  function cancelInvite(id) {
    openModal({
      kind: 'confirm',
      title: 'Anulować wysyłkę?',
      body: 'Zaproszenie zostanie usunięte z inboxa.',
      confirmAction: 'cancel-invite',
      confirmLabel: 'Anuluj wysyłkę',
      danger: true,
      id,
    });
  }

  function handleAction(action, element) {
    const id = element?.dataset?.id;
    if (action === 'tab') {
      const destination = element.dataset.tab;
      if (destination !== state.destination) {
        state.destination = destination;
      }
      state.routeStack = [{ kind: 'list' }];
      state.modal = null;
      save();
      render();
      return;
    }
    if (action === 'back') return goBack();
    if (action === 'open-account') return openAccount();
    if (action === 'open-settings') return openSettings();
    if (action === 'open-tor') return openTor();
    if (action === 'open-new-contact') return openNewContact();
    if (action === 'open-qr') return openQr();
    if (action === 'open-actions') return openActions(route().kind);
    if (action === 'open-contact') return openContact(id);
    if (action === 'open-contact-from-route') {
      const current = route();
      if (current.kind === 'conversation') return openContact(current.id);
      return;
    }
    if (action === 'open-chat') return openConversation(id);
    if (action === 'open-invite') return openInvite(id);
    if (action === 'accept-invite') return acceptInvite(id);
    if (action === 'reject-invite') return rejectInvite(id);
    if (action === 'cancel-invite') return cancelInvite(id);
    if (action === 'copy-code') {
      const current = route();
      const code = current.kind === 'invite'
        ? (state.inbox.find((item) => item.id === current.id)?.code || state.profile.inviteCode)
        : state.profile.inviteCode;
      copyText(code);
      return openModal({
        kind: 'error',
        title: 'Skopiowano',
        body: 'Kod został skopiowany do schowka.',
      });
    }
    if (action === 'copy-fingerprint') {
      const current = route();
      const fingerprint = current.kind === 'contact'
        ? (state.contacts.find((item) => item.id === current.id)?.fingerprint || state.profile.fingerprint)
        : current.kind === 'conversation'
          ? (state.conversations.find((item) => item.id === current.id)?.fingerprint || state.profile.fingerprint)
          : state.profile.fingerprint;
      copyText(fingerprint);
      return openModal({
        kind: 'error',
        title: 'Skopiowano',
        body: 'Fingerprint został skopiowany do schowka.',
      });
    }
    if (action === 'copy-onion') {
      copyText(state.transport.onion);
      return openModal({
        kind: 'error',
        title: 'Skopiowano',
        body: 'Adres onion został skopiowany do schowka.',
      });
    }
    if (action === 'toggle-theme') {
      state.theme = state.theme === 'dark' ? 'light' : 'dark';
      save();
      render();
      return;
    }
    if (action === 'toggle-tor') {
      state.transport.status = state.transport.status === 'connected' ? 'error' : 'connected';
      if (state.transport.status === 'connected') state.transport.queue = [];
      save();
      render();
      return;
    }
    if (action === 'retry-tor') {
      state.transport.status = 'connected';
      save();
      render();
      return;
    }
    if (action === 'confirm-modal') {
      return resolveConfirm(element.dataset.confirm);
    }
    if (action === 'close-modal') {
      state.modal = null;
      save();
      render();
      return;
    }
    if (action === 'send-invite') return sendInvite();
    if (action === 'save-nickname') return saveNickname();
    if (action === 'save-settings') return saveNickname('settings-nickname');
    if (action === 'open-confirm') {
      const confirm = element.dataset.confirm;
      if (confirm === 'reset') {
        return openModal({
          kind: 'confirm',
          title: 'Zresetować dane demo?',
          body: 'Usunie lokalny stan maquette i przywróci start.',
          confirmAction: 'reset',
          confirmLabel: 'Resetuj',
          danger: true,
        });
      }
      if (confirm === 'disconnect') {
        return openModal({
          kind: 'confirm',
          title: 'Symulować rozłączenie?',
          body: 'Tor przejdzie w tryb offline do czasu ponownego połączenia.',
          confirmAction: 'disconnect',
          confirmLabel: 'Przełącz',
          danger: true,
        });
      }
    }
  }

  function saveNickname(fieldName = 'nickname') {
    const input = document.querySelector(`[data-field="${fieldName}"]`);
    const value = input?.value.trim();
    if (!value || value.length < 2 || value.length > 32) {
      return openModal({
        kind: 'error',
        title: 'Nieprawidłowy nick',
        body: 'Nick musi mieć 2-32 znaki.',
      });
    }
    state.profile.nickname = value;
    state.screen = 'main';
    save();
    render();
  }

  function sendInvite() {
    const input = document.querySelector('[data-field="invite-code"]');
    const value = input?.value.trim() || '';
    if (!/^\d{8}$/.test(value)) {
      return openModal({
        kind: 'error',
        title: 'Nieprawidłowy kod',
        body: 'Kod musi zawierać dokładnie 8 cyfr.',
      });
    }
    state.inbox.unshift({
      id: `out-${Date.now()}`,
      name: 'Nowy kontakt',
      initial: '?',
      code: value,
      kind: 'sent',
      status: 'pending',
      note: 'Wysłane z tej instancji',
    });
    state.modal = null;
    save();
    render();
  }

  function sendMessage(event) {
    event.preventDefault();
    const current = route();
    if (current.kind !== 'conversation') return;
    const conversation = state.conversations.find((item) => item.id === current.id);
    const input = event.currentTarget.querySelector('[data-field="message"]');
    const value = input.value.trim();
    if (!value || !conversation) return;
    conversation.messages.push({ from: state.profile.nickname, body: value, time: now() });
    conversation.preview = value;
    conversation.time = now();
    if (state.transport.status !== 'connected') {
      if (!state.transport.queue.includes(conversation.id)) state.transport.queue.push(conversation.id);
    } else {
      setTimeout(() => {
        conversation.messages.push({ from: conversation.name, body: 'Odebrano. To jest odpowiedź demonstracyjna.', time: now() });
        conversation.preview = 'Odebrano. To jest odpowiedź demonstracyjna.';
        conversation.time = now();
        save();
        render();
      }, 700);
    }
    input.value = '';
    save();
    render();
  }

  function updateSearch(value) {
    state.search[state.destination] = value;
    save();
    markFocus('search');
    render();
  }

  function handleInput(event) {
    const input = event.target.closest('[data-field]');
    if (!input) return;
    if (input.dataset.field === 'search') return updateSearch(input.value);
  }

  function handleSubmit(event) {
    const form = event.target.closest('form');
    if (!form) return;
    if (form.dataset.action === 'send-message') return sendMessage(event);
  }

  function handleClick(event) {
    const action = event.target.closest('[data-action]');
    if (!action) return;
    event.preventDefault();
    handleAction(action.dataset.action, action);
  }

  function tickInviteCode() {
    if (state.profile.inviteExpires > 0) {
      state.profile.inviteExpires -= 1;
    } else {
      state.profile.inviteExpires = 60;
      state.profile.inviteCode = String(Math.floor(10000000 + Math.random() * 90000000));
    }
    save();
    if (state.screen === 'main' && (route().kind === 'account' || state.modal?.kind === 'qr')) render();
  }

  document.addEventListener('click', handleClick);
  document.addEventListener('submit', handleSubmit);
  document.addEventListener('input', handleInput);
  window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      if (state.modal) {
        state.modal = null;
        save();
        render();
        return;
      }
      if (!isRoot()) {
        goBack();
      }
      return;
    }
    if (event.ctrlKey && event.key.toLowerCase() === 'k') {
      const field = document.querySelector('[data-field="search"]');
      if (field) {
        event.preventDefault();
        field.focus();
      }
    }
  });

  const compactQuery = window.matchMedia('(max-width: 899px)');
  if (compactQuery.addEventListener) {
    compactQuery.addEventListener('change', render);
  } else {
    compactQuery.addListener(render);
  }

  // Developer-only console API. It resets only this platform's local maquette state.
  window.app = {
    reset() {
      localStorage.removeItem(storageKey);
      state = normalizeState(null);
      render();
      return 'TorChat maquette reset.';
    },
  };

  window.startTorChat = () => {
    if (state.screen === 'splash') {
      render();
      setTimeout(() => {
        state.screen = 'tor';
        state.transport.status = 'connecting';
        render();
        setTimeout(() => {
          state.screen = 'nickname';
          state.transport.status = 'connected';
          save();
          render();
        }, 900);
      }, 800);
    } else {
      render();
    }
    setInterval(tickInviteCode, 1000);
  };
})();
