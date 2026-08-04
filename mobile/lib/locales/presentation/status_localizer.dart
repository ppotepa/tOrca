import '../../core/connection/connection_component.dart';
import '../../core/models/domain.dart';
import '../../core/presence/contact_presence_snapshot.dart';
import '../../locales/generated/app_localizations.dart';

String localizeTransportPhase(AppLocalizations l10n, TransportPhase phase) =>
    switch (phase) {
      TransportPhase.connected => l10n.statusTransportConnected,
      TransportPhase.starting => l10n.statusTransportStarting,
      TransportPhase.bootstrapping => l10n.statusTransportBootstrapping,
      TransportPhase.connecting => l10n.statusTransportConnecting,
      TransportPhase.degraded => l10n.statusTransportDegraded,
      TransportPhase.reconnecting => l10n.statusTransportReconnecting,
      TransportPhase.offline => l10n.statusTransportOffline,
      TransportPhase.error => l10n.statusTransportError,
    };

String localizeConnectionComponentTitle(
  AppLocalizations l10n,
  ConnectionComponent component,
) => switch (component) {
  ConnectionComponent.engine => l10n.statusComponentEngine,
  ConnectionComponent.localData => l10n.statusComponentLocalData,
  ConnectionComponent.tor => l10n.statusComponentTor,
  ConnectionComponent.peerListener => l10n.statusComponentPeerListener,
  ConnectionComponent.onionService => l10n.statusComponentOnionService,
};

String localizeConnectionComponentDescription(
  AppLocalizations l10n,
  ConnectionComponent component,
) => switch (component) {
  ConnectionComponent.engine => l10n.statusComponentEngineDescription,
  ConnectionComponent.localData => l10n.statusComponentLocalDataDescription,
  ConnectionComponent.tor => l10n.statusComponentTorDescription,
  ConnectionComponent.peerListener =>
    l10n.statusComponentPeerListenerDescription,
  ConnectionComponent.onionService =>
    l10n.statusComponentOnionServiceDescription,
};

String localizeProbeLabel(AppLocalizations l10n, String id) => switch (id) {
  'engine' => l10n.statusProbeEngine,
  'peer' => l10n.statusProbePeer,
  _ => id,
};

String localizeStartupStepTitle(AppLocalizations l10n, StartupStepKind kind) =>
    switch (kind) {
      StartupStepKind.engine => l10n.startupEngine,
      StartupStepKind.localData => l10n.startupLocalData,
      StartupStepKind.tor => l10n.startupTor,
      StartupStepKind.peerListener => l10n.startupPeerListener,
      StartupStepKind.onionService => l10n.startupOnionService,
      StartupStepKind.communication => l10n.startupCommunication,
    };

String localizeStartupStepDescription(
  AppLocalizations l10n,
  StartupStepKind kind,
) => switch (kind) {
  StartupStepKind.engine => l10n.startupEngineDescription,
  StartupStepKind.localData => l10n.startupLocalDataDescription,
  StartupStepKind.tor => l10n.startupTorDescription,
  StartupStepKind.peerListener => l10n.startupPeerListenerDescription,
  StartupStepKind.onionService => l10n.startupOnionServiceDescription,
  StartupStepKind.communication => l10n.startupCommunicationDescription,
};

String localizeContactRoute(AppLocalizations l10n, ContactRecord contact) {
  if (contact.peerConnectionStatus == PeerConnectionStatus.connected) {
    return l10n.contactRouteP2pOnion;
  }
  return l10n.contactRouteP2pOffline;
}

String localizePeerEndpointStatus(
  AppLocalizations l10n,
  PeerEndpointStatus status,
) => switch (status) {
  PeerEndpointStatus.verified => l10n.contactEndpointVerified,
  PeerEndpointStatus.pendingExchange => l10n.contactEndpointPending,
  PeerEndpointStatus.invalid => l10n.contactEndpointInvalid,
  PeerEndpointStatus.missing => l10n.contactEndpointMissing,
};

String localizeContactAvailability(
  AppLocalizations l10n,
  ContactAvailability value,
) => switch (value) {
  ContactAvailability.active => l10n.contactAvailabilityActive,
  ContactAvailability.idle => l10n.contactAvailabilityIdle,
  ContactAvailability.checking => l10n.contactAvailabilityChecking,
  ContactAvailability.offline => l10n.contactAvailabilityOffline,
  ContactAvailability.unknown => l10n.contactAvailabilityUnknown,
};

String localizePeerConnectionStatus(
  AppLocalizations l10n,
  PeerConnectionStatus status,
) => switch (status) {
  PeerConnectionStatus.connected => l10n.contactPeerConnected,
  PeerConnectionStatus.connecting => l10n.contactPeerConnecting,
  PeerConnectionStatus.authenticating => l10n.contactPeerAuthenticating,
  PeerConnectionStatus.backoff => l10n.contactPeerBackoff,
  PeerConnectionStatus.offline => l10n.contactPeerOffline,
};

String localizeTransportPolicy(
  AppLocalizations l10n,
  ContactTransportPolicy policy,
) => switch (policy) {
  ContactTransportPolicy.peerOnly => l10n.contactPolicyP2pOnly,
};
