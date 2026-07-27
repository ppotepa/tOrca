import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'client_runtime.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TorChatMobileApp());
}

class TorChatMobileApp extends StatelessWidget {
  const TorChatMobileApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TorChat',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff61d095),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff101318),
      useMaterial3: true,
    ),
    home: const MobileHomePage(),
  );
}

enum AppScreen { splash, tor, nickname, main }

enum MobileTab { chats, contacts, inbox }

class MobileContactRequest {
  const MobileContactRequest({required this.id, required this.peer, required this.status, required this.invitePayload, required this.expiresAt});
  final String id;
  final MobileContact peer;
  final String status;
  final String? invitePayload;
  final int expiresAt;

  factory MobileContactRequest.fromMap(Map<String, dynamic> map, {required bool inbox}) => MobileContactRequest(
    id: map['pairingId'] as String? ?? '',
    peer: MobileContact.fromMap(Map<String, dynamic>.from(map['sender'] as Map? ?? const {})),
    status: map['state'] as String? ?? 'PENDING',
    invitePayload: null,
    expiresAt: (map['expiresAt'] as num?)?.toInt() ?? 0,
  );
}

class MobileContact {
  const MobileContact({
    required this.id,
    required this.nickname,
    required this.fingerprint,
    required this.publicKey,
    required this.verified,
    this.devFixture,
  });
  final String id;
  final String nickname;
  final String fingerprint;
  final String publicKey;
  final bool verified;
  final String? devFixture;

  factory MobileContact.fromMap(Map<String, dynamic> map) => MobileContact(
    id: map['installationId'] as String? ?? '',
    nickname: map['nickname'] as String? ?? 'Nieznany',
    fingerprint: map['fingerprint'] as String? ?? '',
    publicKey: map['publicKey'] as String? ?? '',
    verified: map['verification'] == 'VERIFIED',
    devFixture: map['dev'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'installationId': id,
    'nickname': nickname,
    'fingerprint': fingerprint,
    'publicKey': publicKey,
    'verification': verified ? 'VERIFIED' : 'UNVERIFIED',
    if (devFixture != null) 'dev': devFixture,
  };
}

class MobileConversation {
  const MobileConversation({
    required this.id,
    required this.contactId,
    required this.preview,
    required this.unread,
  });
  final String id;
  final String contactId;
  final String preview;
  final int unread;

  factory MobileConversation.fromMap(Map<String, dynamic> map) =>
      MobileConversation(
        id: map['id'] as String? ?? '',
        contactId: map['contactInstallationId'] as String? ?? '',
        preview: map['lastMessagePreview'] as String? ?? 'Nowa rozmowa',
        unread: (map['unreadCount'] as num?)?.toInt() ?? 0,
      );
}

class MobileMessage {
  const MobileMessage({
    required this.text,
    required this.outgoing,
    required this.state,
  });
  final String text;
  final bool outgoing;
  final String state;

  factory MobileMessage.fromMap(Map<String, dynamic> map) => MobileMessage(
    text: map['body'] as String? ?? '',
    outgoing: map['outgoing'] as bool? ?? false,
    state: map['state'] as String? ?? '',
  );
}

class _MobileHomePageState extends State<MobileHomePage> {
  final ClientRuntime _bridge = createClientRuntime();
  final _searchController = TextEditingController();
  final _composerController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _events;
  AppScreen _screen = AppScreen.splash;
  MobileTab _tab = MobileTab.chats;
  String _status = 'Przygotowywanie Tor…';
  String _statusDetail = '';
  int? _progress;
  String _nickname = '';
  String _fingerprint = '';
  String _pairingCode = '';
  String _error = '';
  bool _connecting = false;
  List<MobileContact> _contacts = const [];
  List<MobileContact> _searchResults = const [];
  List<MobileConversation> _conversations = const [];
  List<MobileMessage> _messages = const [];
  List<MobileContactRequest> _inbox = const [];
  List<MobileContactRequest> _outbox = const [];
  String? _selectedConversation;

  @override
  void initState() {
    super.initState();
    _events = _bridge.events.listen(
      _onEvent,
      onError: (Object error) => _fail(error.toString()),
    );
    Future<void>.delayed(const Duration(milliseconds: 850), _startRuntime);
  }

  @override
  void dispose() {
    _events?.cancel();
    _searchController.dispose();
    _composerController.dispose();
    super.dispose();
  }

  Future<void> _startRuntime() async {
    if (!mounted) return;
    setState(() {
      _screen = AppScreen.tor;
      _connecting = true;
    });
    try {
      await _bridge.connect();
    } on PlatformException catch (error) {
      _fail(error.message ?? error.code);
    } catch (error) {
      _fail(error.toString());
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'tor_status':
        setState(() {
          _status = _statusLabel(event['phase'] as String? ?? '');
          _statusDetail = event['detail'] as String? ?? '';
          _progress = (event['progress'] as num?)?.toInt();
          if (event['phase'] == 'connected') _connecting = false;
        });
      case 'profile_ready':
        final profile = Map<String, dynamic>.from(
          event['profile'] as Map? ?? const {},
        );
        final identity = Map<String, dynamic>.from(
          event['identity'] as Map? ?? const {},
        );
        setState(() {
          _nickname = profile['nickname'] as String? ?? '';
          _fingerprint =
              identity['fingerprint'] as String? ??
              profile['fingerprint'] as String? ??
              '';
          _pairingCode = '';
          _connecting = false;
          _screen = _nickname.trim().isEmpty
              ? AppScreen.nickname
              : AppScreen.main;
        });
        _loadLocalState();
      case 'message_received':
      case 'chat_state_changed':
        _loadLocalState();
      case 'runtime_error':
        _fail(event['message'] as String? ?? 'Runtime error');
    }
  }

  String _statusLabel(String phase) => switch (phase) {
    'starting' => 'Uruchamianie Tor',
    'bootstrapping' => 'Łączenie z siecią Tor',
    'onion_connecting' => 'Łączenie z onion',
    'connected' => 'Onion połączony · relay aktywny',
    _ => 'Rozłączony',
  };

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _error = message;
      _status = 'Błąd połączenia Tor';
    });
  }

  Future<void> _loadLocalState() async {
    try {
      final selectedConversation = _selectedConversation;
      final contacts = await _bridge.contacts();
      final conversations = await _bridge.conversations();
      final inbox = await _bridge.pairingInbox();
      final messages = selectedConversation == null
          ? null
          : await _bridge.messages(selectedConversation);
      if (!mounted) return;
      setState(() {
        _contacts = contacts.map(MobileContact.fromMap).toList();
        _conversations = conversations.map(MobileConversation.fromMap).toList();
        _inbox = inbox.map((item) => MobileContactRequest.fromMap(item, inbox: true)).toList();
        _outbox = const [];
        if (messages != null && _selectedConversation == selectedConversation) {
          _messages = messages.map(MobileMessage.fromMap).toList();
        }
      });
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _saveNickname() async {
    final value = _nickname.trim();
    if (value.length < 2) {
      setState(() => _error = 'Nick musi mieć co najmniej 2 znaki');
      return;
    }
    try {
      final profile = await _bridge.setNickname(value);
      setState(() {
        _nickname = profile['nickname'] as String? ?? value;
        _error = '';
        _screen = AppScreen.main;
      });
      _loadLocalState();
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _search() async {
    try {
      final code = _searchController.text.replaceAll(RegExp(r'\D'), '');
      if (code.length != 8) throw StateError('Wpisz dokładnie 8 cyfr kodu parowania.');
      await _bridge.submitPairingCode(code);
      if (mounted) {
        setState(() { _searchResults = const []; _error = 'Prośba wysłana. Czekaj na akceptację drugiej osoby.'; });
      }
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _openConversation(String id) async {
    try {
      await _bridge.openConversation(id);
      final messages = await _bridge.messages(id);
      if (!mounted) return;
      setState(() {
        _selectedConversation = id;
        _messages = messages.map(MobileMessage.fromMap).toList();
        _tab = MobileTab.chats;
        _error = '';
      });
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _startConversation(MobileContact contact) async {
    final existing = _conversations
        .where((item) => item.contactId == contact.id)
        .firstOrNull;
    if (existing != null) {
      await _openConversation(existing.id);
      return;
    }
    _fail('Dodaj nowy kontakt przez 8-cyfrowy kod parowania.');
  }

  Future<void> _scanInvite() async {
    final invite = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _InviteScannerPage()),
    );
    if (invite == null || invite.trim().isEmpty) return;
    try {
      _searchController.text = invite.replaceAll(RegExp(r'\D'), '');
      await _search();
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _showOwnInvite() async {
    final freshCode = await _bridge.refreshPairingCode();
    if (!mounted || freshCode == null) return;
    setState(() => _pairingCode = freshCode['code'] as String? ?? '');
    await showDialog<void>(
      context: context,
      builder: (_) => _PairingCodeDialog(
        initialCode: _pairingCode,
        refresh: _bridge.refreshPairingCode,
        onChanged: (code) {
          if (mounted) setState(() => _pairingCode = code);
        },
      ),
    );
  }

  Future<void> _send() async {
    final id = _selectedConversation;
    final text = _composerController.text.trim();
    if (id == null || text.isEmpty) return;
    try {
      await _bridge.sendMessage(id, text);
      _composerController.clear();
      await _openConversation(id);
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _verifyContact(String installationId) async {
    try {
      await _bridge.verifyContact(installationId);
      await _loadLocalState();
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _acceptRequest(MobileContactRequest request) async {
    try {
      await _bridge.acceptPairing(request.id);
      await _loadLocalState();
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _rejectRequest(MobileContactRequest request) async {
    try {
      await _bridge.rejectPairing(request.id);
      await _loadLocalState();
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _cancelRequest(MobileContactRequest request) async {
    try {
      await _bridge.rejectPairing(request.id);
      await _loadLocalState();
    } catch (error) {
      _fail(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => switch (_screen) {
    AppScreen.splash => const _SplashScreen(),
    AppScreen.tor => _TorScreen(
      status: _status,
      detail: _statusDetail,
      progress: _progress,
      error: _error,
      retry: _startRuntime,
      connecting: _connecting,
    ),
    AppScreen.nickname => _NicknameScreen(
      value: _nickname,
      error: _error,
      onChanged: (value) => setState(() => _nickname = value),
      onSave: _saveNickname,
    ),
    AppScreen.main => _MainScreen(
      tab: _tab,
      nickname: _nickname,
      fingerprint: _fingerprint,
      ownInvite: _pairingCode,
      status: _status,
      contacts: _contacts,
      searchResults: _searchResults,
      conversations: _conversations,
      messages: _messages,
      selectedConversation: _selectedConversation,
      inbox: _inbox,
      outbox: _outbox,
      search: _searchController,
      composer: _composerController,
      error: _error,
      onTab: (tab) => setState(() => _tab = tab),
      onSearch: _search,
      onOpenConversation: _openConversation,
      onStartConversation: _startConversation,
      onScanInvite: _scanInvite,
      onShowInvite: _showOwnInvite,
      onSend: _send,
      onVerifyContact: _verifyContact,
      onBack: () => setState(() => _selectedConversation = null),
      onAcceptRequest: _acceptRequest,
      onRejectRequest: _rejectRequest,
      onCancelRequest: _cancelRequest,
    ),
  };
}

class MobileHomePage extends StatefulWidget {
  const MobileHomePage({super.key});
  @override
  State<MobileHomePage> createState() => _MobileHomePageState();
}

class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog({required this.initialCode, required this.refresh, required this.onChanged});
  final String initialCode;
  final Future<Map<String, dynamic>?> Function() refresh;
  final ValueChanged<String> onChanged;
  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  late String _code = widget.initialCode;
  Timer? _timer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 55), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final fresh = await widget.refresh();
      final code = fresh?['code'] as String? ?? '';
      if (mounted && code.isNotEmpty) {
        setState(() => _code = code);
        widget.onChanged(code);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Twój kod parowania'),
    content: SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: QrImageView(
              data: _code,
              size: 240,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(color: Colors.black),
              dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(_code, style: const TextStyle(letterSpacing: 4, fontWeight: FontWeight.bold)),
          TextButton.icon(
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
            label: const Text('Odśwież kod'),
          ),
        ],
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zamknij'))],
  );
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.eco, size: 72, color: Color(0xff61d095)),
          SizedBox(height: 16),
          Text(
            'TorChat',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text('Prywatne wiadomości przez Tor'),
        ],
      ),
    ),
  );
}

class _TorScreen extends StatelessWidget {
  const _TorScreen({
    required this.status,
    required this.detail,
    required this.progress,
    required this.error,
    required this.retry,
    required this.connecting,
  });
  final String status, detail, error;
  final int? progress;
  final VoidCallback retry;
  final bool connecting;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.eco, size: 64, color: Colors.amber),
              const SizedBox(height: 18),
              Text(
                status,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (progress != null) ...[
                const SizedBox(height: 18),
                LinearProgressIndicator(value: progress! / 100),
                const SizedBox(height: 8),
                Text('$progress%'),
              ],
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(detail, textAlign: TextAlign.center),
              ],
              if (error.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: retry,
                  child: const Text('Spróbuj ponownie'),
                ),
              ],
              if (error.isEmpty && connecting)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NicknameScreen extends StatelessWidget {
  const _NicknameScreen({
    required this.value,
    required this.error,
    required this.onChanged,
    required this.onSave,
  });
  final String value, error;
  final ValueChanged<String> onChanged;
  final VoidCallback onSave;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.person_outline,
              size: 56,
              color: Color(0xff61d095),
            ),
            const SizedBox(height: 20),
            Text(
              'Ustaw swój nick',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            TextField(
              onChanged: onChanged,
              onSubmitted: (_) => onSave(),
              decoration: const InputDecoration(
                labelText: 'Nick',
                border: OutlineInputBorder(),
              ),
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onSave, child: const Text('Zapisz nick')),
          ],
        ),
      ),
    ),
  );
}

class _MainScreen extends StatelessWidget {
  const _MainScreen({
    required this.tab,
    required this.nickname,
    required this.fingerprint,
    required this.ownInvite,
    required this.status,
    required this.contacts,
    required this.searchResults,
    required this.conversations,
    required this.messages,
    required this.inbox,
    required this.outbox,
    required this.selectedConversation,
    required this.search,
    required this.composer,
    required this.error,
    required this.onTab,
    required this.onSearch,
    required this.onOpenConversation,
    required this.onStartConversation,
    required this.onScanInvite,
    required this.onShowInvite,
    required this.onSend,
    required this.onVerifyContact,
    required this.onBack,
    required this.onAcceptRequest,
    required this.onRejectRequest,
    required this.onCancelRequest,
  });
  final MobileTab tab;
  final String nickname, fingerprint, ownInvite, status, error;
  final List<MobileContact> contacts, searchResults;
  final List<MobileConversation> conversations;
  final List<MobileMessage> messages;
  final List<MobileContactRequest> inbox, outbox;
  final String? selectedConversation;
  final TextEditingController search, composer;
  final ValueChanged<MobileTab> onTab;
  final VoidCallback onSearch, onSend, onBack;
  final ValueChanged<String> onVerifyContact;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<MobileContact> onStartConversation;
  final VoidCallback onScanInvite, onShowInvite;
  final ValueChanged<MobileContactRequest> onAcceptRequest, onRejectRequest, onCancelRequest;

  MobileContact? contactFor(String id) => [
    ...contacts,
    ...searchResults,
  ].where((contact) => contact.id == id).firstOrNull;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TorChat'),
          Text('@$nickname', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      actions: [_StatusPill(status), const SizedBox(width: 8)],
    ),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: tab == MobileTab.chats
            ? _ChatsView(
                selected: contactFor(selectedConversation ?? ''),
                contacts: contacts,
                conversations: conversations,
                messages: messages,
                composer: composer,
                onOpenConversation: onOpenConversation,
                onSend: onSend,
                onVerifyContact: onVerifyContact,
                onBack: onBack,
                error: error,
              )
            : tab == MobileTab.contacts
            ? _ContactsView(
                saved: contacts,
                results: searchResults,
                search: search,
                onSearch: onSearch,
                onSelect: onStartConversation,
                onScanInvite: onScanInvite,
                onShowInvite: onShowInvite,
                fingerprint: fingerprint,
                ownInvite: ownInvite,
              )
            : _InboxView(
                inbox: inbox,
                outbox: outbox,
                onAccept: onAcceptRequest,
                onReject: onRejectRequest,
                onCancel: onCancelRequest,
              ),
      ),
    ),
    bottomNavigationBar: selectedConversation == null
        ? NavigationBar(
            selectedIndex: tab.index,
            onDestinationSelected: (index) => onTab(MobileTab.values[index]),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                label: 'Czaty',
              ),
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                label: 'Kontakty',
              ),
              NavigationDestination(
                icon: Icon(Icons.mark_email_unread_outlined),
                label: 'Inbox',
              ),
            ],
          )
        : null,
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.status);
  final String status;
  @override
  Widget build(BuildContext context) {
    final color = status.contains('aktywny')
        ? const Color(0xff61d095)
        : status.contains('Błąd')
        ? Colors.redAccent
        : status.contains('Rozłączony')
        ? Colors.blueGrey
        : Colors.amber;
    return Tooltip(
      message: status,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.eco, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatsView extends StatelessWidget {
  const _ChatsView({
    required this.selected,
    required this.contacts,
    required this.conversations,
    required this.messages,
    required this.composer,
    required this.onOpenConversation,
    required this.onSend,
    required this.onVerifyContact,
    required this.onBack,
    required this.error,
  });
  final MobileContact? selected;
  final List<MobileContact> contacts;
  final List<MobileConversation> conversations;
  final List<MobileMessage> messages;
  final TextEditingController composer;
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onSend, onBack;
  final ValueChanged<String> onVerifyContact;
  final String error;
  @override
  Widget build(BuildContext context) {
    if (selected == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Czaty', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          if (conversations.isEmpty)
            const Expanded(
              child: Center(
                child: Text(
                  'Nie masz jeszcze rozmów.\nWybierz osobę w zakładce Kontakty.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: conversations.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  final contact = contacts
                      .where((item) => item.id == conversation.contactId)
                      .firstOrNull;
                  final name = contact?.nickname.trim().isNotEmpty == true
                      ? contact!.nickname
                      : 'Nieznany kontakt';
                  return Card(
                    child: ListTile(
                      onTap: () => onOpenConversation(conversation.id),
                      leading: CircleAvatar(child: Text(_initial(name))),
                      title: Text(name),
                      subtitle: Text(
                        conversation.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: conversation.unread > 0
                          ? Badge(label: Text('${conversation.unread}'))
                          : const Icon(Icons.chevron_right),
                    ),
                  );
                },
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
            CircleAvatar(radius: 17, child: Text(_initial(selected!.nickname))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selected!.nickname,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    'MLS · przez onion',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        Expanded(
          child: messages.isEmpty
              ? const Center(child: Text('Napisz pierwszą wiadomość.'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) =>
                      _MessageBubble(message: messages[index]),
                ),
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error, style: const TextStyle(color: Colors.redAccent)),
          ),
        if (!selected!.verified)
          Card(
            color: const Color(0xff3b3020),
            child: ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('Potwierdź fingerprint'),
              subtitle: Text(selected!.fingerprint),
              trailing: FilledButton(
                onPressed: () => onVerifyContact(selected!.id),
                child: const Text('Potwierdzam'),
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: composer,
                textInputAction: TextInputAction.send,
                minLines: 1,
                maxLines: 4,
                onSubmitted: selected!.verified ? (_) => onSend() : null,
                decoration: const InputDecoration(
                  hintText: 'Napisz wiadomość…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: selected!.verified ? onSend : null, icon: const Icon(Icons.send)),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final MobileMessage message;

  @override
  Widget build(BuildContext context) => Align(
    alignment: message.outgoing ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * .76,
      ),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 7),
      decoration: BoxDecoration(
        color: message.outgoing
            ? const Color(0xff244c3d)
            : const Color(0xff202832),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(message.text),
          if (message.outgoing) ...[
            const SizedBox(height: 3),
            Text(
              _messageState(message.state),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: Colors.white60),
            ),
          ],
        ],
      ),
    ),
  );
}

class _InboxView extends StatelessWidget {
  const _InboxView({required this.inbox, required this.outbox, required this.onAccept, required this.onReject, required this.onCancel});
  final List<MobileContactRequest> inbox, outbox;
  final ValueChanged<MobileContactRequest> onAccept, onReject, onCancel;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      Text('Zaproszenia', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 12),
      if (inbox.isEmpty && outbox.isEmpty)
        const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Brak zaproszeń.'))),
      if (inbox.isNotEmpty) ...[
        Text('Odebrane', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        ...inbox.map((request) => Card(
          child: ListTile(
            leading: CircleAvatar(child: Text(_initial(request.peer.nickname))),
            title: Text('@${request.peer.nickname}'),
            subtitle: Text('${request.peer.fingerprint}\nStatus: ${request.status}'),
            isThreeLine: true,
            trailing: request.status == 'PENDING'
                ? Wrap(spacing: 4, children: [
                    IconButton(onPressed: () => onAccept(request), icon: const Icon(Icons.check, color: Colors.greenAccent)),
                    IconButton(onPressed: () => onReject(request), icon: const Icon(Icons.close, color: Colors.redAccent)),
                  ])
                : null,
          ),
        )),
      ],
      if (outbox.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Wysłane', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        ...outbox.map((request) => Card(
          child: ListTile(
            leading: CircleAvatar(child: Text(_initial(request.peer.nickname))),
            title: Text('@${request.peer.nickname}'),
            subtitle: Text('${request.peer.fingerprint}\nStatus: ${request.status}'),
            isThreeLine: true,
            trailing: request.status == 'PENDING'
                ? IconButton(onPressed: () => onCancel(request), icon: const Icon(Icons.cancel_outlined))
                : null,
          ),
        )),
      ],
    ],
  );
}

class _ContactsView extends StatelessWidget {
  const _ContactsView({
    required this.saved,
    required this.results,
    required this.search,
    required this.onSearch,
    required this.onSelect,
    required this.onScanInvite,
    required this.onShowInvite,
    required this.fingerprint,
    required this.ownInvite,
  });
  final List<MobileContact> saved, results;
  final TextEditingController search;
  final VoidCallback onSearch;
  final ValueChanged<MobileContact> onSelect;
  final VoidCallback onScanInvite, onShowInvite;
  final String fingerprint, ownInvite;
  @override
  Widget build(BuildContext context) {
    final visible = <MobileContact>[];
    for (final contact in [...saved, ...results]) {
      if (contact.id.isNotEmpty &&
          !visible.any((item) => item.id == contact.id)) {
        visible.add(contact);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Kontakty',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            IconButton.filledTonal(
              onPressed: onScanInvite,
              tooltip: 'Skanuj invite',
              icon: const Icon(Icons.qr_code_scanner),
            ),
            IconButton.filledTonal(
              onPressed: onShowInvite,
              tooltip: 'Mój kod parowania',
              icon: const Icon(Icons.qr_code),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: search,
          onSubmitted: (_) => onSearch(),
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: InputDecoration(
            counterText: '',
            hintText: 'Wpisz 8-cyfrowy kod parowania',
            prefixIcon: const Icon(Icons.password),
            suffixIcon: IconButton(
              onPressed: onSearch,
              icon: const Icon(Icons.arrow_forward),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('Brak kontaktów.'))
              : ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 5),
                  itemBuilder: (context, index) {
                    final contact = visible[index];
                    return _ContactTile(
                      contact: contact,
                      onTap: () => onSelect(contact),
                    );
                  },
                ),
        ),
        const SizedBox(height: 8),
        Text('Twój fingerprint', style: Theme.of(context).textTheme.labelLarge),
        Text(
          fingerprint,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, required this.onTap});
  final MobileContact contact;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final name = contact.nickname.trim().isEmpty
        ? 'Nieznany kontakt'
        : contact.nickname.trim();
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(child: Text(_initial(name))),
        title: Text(name),
        subtitle: Text(
          contact.fingerprint.isEmpty
              ? 'Fingerprint niedostępny'
              : contact.fingerprint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (contact.devFixture != null) const Chip(label: Text('DEV')),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

String _initial(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? '?' : normalized.characters.first.toUpperCase();
}

String _messageState(String value) => switch (value.toUpperCase()) {
  'PENDING' => 'wysyłanie…',
  'SENT' => 'wysłano',
  'DELIVERED' => 'dostarczono',
  'FAILED' => 'błąd wysyłania',
  _ => value.toLowerCase(),
};

class _InviteScannerPage extends StatelessWidget {
  const _InviteScannerPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Skanuj invite kontaktu')),
    body: MobileScanner(
      onDetect: (capture) {
        String? value;
        for (final barcode in capture.barcodes) {
          final candidate = barcode.rawValue;
          if (candidate != null && candidate.isNotEmpty) {
            value = candidate;
            break;
          }
        }
        if (value != null && context.mounted) Navigator.of(context).pop(value);
      },
    ),
  );
}
