import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'mobile_bridge.dart';
import 'torchat_ffi.dart';

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

enum MobileTab { chats, contacts }

class MobileContact {
  const MobileContact({
    required this.id,
    required this.nickname,
    required this.fingerprint,
    required this.publicKey,
    this.devFixture,
  });
  final String id;
  final String nickname;
  final String fingerprint;
  final String publicKey;
  final String? devFixture;

  factory MobileContact.fromMap(Map<String, dynamic> map) => MobileContact(
    id: map['installationId'] as String? ?? '',
    nickname: map['nickname'] as String? ?? 'Nieznany',
    fingerprint: map['fingerprint'] as String? ?? '',
    publicKey: map['publicKey'] as String? ?? '',
    devFixture: map['dev'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'installationId': id,
    'nickname': nickname,
    'fingerprint': fingerprint,
    'publicKey': publicKey,
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
  final MobileBridge _bridge = const MobileBridge();
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
  String _ownInvite = '';
  String _error = '';
  bool _connecting = false;
  bool _openingConversation = false;
  List<MobileContact> _contacts = const [];
  List<MobileContact> _searchResults = const [];
  List<MobileConversation> _conversations = const [];
  List<MobileMessage> _messages = const [];
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
          _ownInvite = identity['invite'] as String? ?? '';
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
      final messages = selectedConversation == null
          ? null
          : await _bridge.messages(selectedConversation);
      if (!mounted) return;
      setState(() {
        _contacts = contacts.map(MobileContact.fromMap).toList();
        _conversations = conversations.map(MobileConversation.fromMap).toList();
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
      final results = await _bridge.searchContacts(
        _searchController.text.trim(),
      );
      if (mounted) {
        setState(
          () => _searchResults = results.map(MobileContact.fromMap).toList(),
        );
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
    if (_openingConversation) return;
    final existing = _conversations
        .where((item) => item.contactId == contact.id)
        .firstOrNull;
    if (existing != null) {
      await _openConversation(existing.id);
      return;
    }
    setState(() {
      _openingConversation = true;
      _error = '';
    });
    try {
      await _bridge.startConversation(contact.toMap());
      await _loadLocalState();
      await _openConversation(contact.id);
    } catch (error) {
      _fail(error.toString());
    } finally {
      if (mounted) setState(() => _openingConversation = false);
    }
  }

  Future<void> _scanInvite() async {
    final invite = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _InviteScannerPage()),
    );
    if (invite == null || invite.trim().isEmpty) return;
    try {
      final normalizedInvite = invite.trim();
      final inviteJson = jsonDecode(normalizedInvite) as Map<String, dynamic>;
      final ffiValidation = TorchatFfi.instance.validateContactInvite(
        normalizedInvite,
      );
      if (ffiValidation == false) {
        throw StateError(
          TorchatFfi.instance.lastError() ?? 'Nieprawidłowy invite kontaktu.',
        );
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Potwierdź fingerprint'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Kontakt: ${inviteJson['nickname'] ?? 'Nieznany'}'),
              const SizedBox(height: 12),
              const Text('Fingerprint', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SelectableText('${inviteJson['fingerprint'] ?? ''}'),
              const SizedBox(height: 12),
              const Text('Porównaj ten kod z drugą osobą przed akceptacją.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Akceptuj zaproszenie'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final conversationId = await _bridge.startConversationFromInvite(
        normalizedInvite,
      );
      await _loadLocalState();
      if (conversationId != null && mounted) {
        await _openConversation(conversationId);
      }
    } catch (error) {
      _fail(error.toString());
    }
  }

  Future<void> _showOwnInvite() async {
    final freshInvite = await _bridge.refreshInvite();
    if (!mounted || freshInvite == null || freshInvite.isEmpty) return;
    setState(() => _ownInvite = freshInvite);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Twój invite MLS'),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QrImageView(data: _ownInvite, size: 240),
              const SizedBox(height: 8),
              SelectableText(_fingerprint),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zamknij'),
          ),
        ],
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
      ownInvite: _ownInvite,
      status: _status,
      contacts: _contacts,
      searchResults: _searchResults,
      conversations: _conversations,
      messages: _messages,
      selectedConversation: _selectedConversation,
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
      onBack: () => setState(() => _selectedConversation = null),
    ),
  };
}

class MobileHomePage extends StatefulWidget {
  const MobileHomePage({super.key});
  @override
  State<MobileHomePage> createState() => _MobileHomePageState();
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
    required this.onBack,
  });
  final MobileTab tab;
  final String nickname, fingerprint, ownInvite, status, error;
  final List<MobileContact> contacts, searchResults;
  final List<MobileConversation> conversations;
  final List<MobileMessage> messages;
  final String? selectedConversation;
  final TextEditingController search, composer;
  final ValueChanged<MobileTab> onTab;
  final VoidCallback onSearch, onSend, onBack;
  final ValueChanged<String> onOpenConversation;
  final ValueChanged<MobileContact> onStartConversation;
  final VoidCallback onScanInvite, onShowInvite;

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
                onBack: onBack,
                error: error,
              )
            : _ContactsView(
                saved: contacts,
                results: searchResults,
                search: search,
                onSearch: onSearch,
                onSelect: onStartConversation,
                onScanInvite: onScanInvite,
                onShowInvite: onShowInvite,
                fingerprint: fingerprint,
                ownInvite: ownInvite,
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
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: composer,
                textInputAction: TextInputAction.send,
                minLines: 1,
                maxLines: 4,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Napisz wiadomość…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: onSend, icon: const Icon(Icons.send)),
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
            if (ownInvite.isNotEmpty)
              IconButton.filledTonal(
                onPressed: onShowInvite,
                tooltip: 'Mój invite',
                icon: const Icon(Icons.qr_code),
              ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: search,
          onSubmitted: (_) => onSearch(),
          decoration: InputDecoration(
            hintText: 'Szukaj po nicku',
            prefixIcon: const Icon(Icons.search),
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
