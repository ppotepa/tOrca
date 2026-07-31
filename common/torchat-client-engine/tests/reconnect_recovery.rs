use torchat_client_engine::{
    ReconnectAction, ReconnectApply, ReconnectEvent, ReconnectProcess, ReconnectState,
};

#[test]
fn repeated_disconnects_remain_recoverable_and_cap_backoff() {
    let mut process = ReconnectProcess::default();
    let mut now_ms = 0_i64;

    assert!(matches!(
        process.apply(ReconnectEvent::NetworkAvailable, now_ms),
        ReconnectApply::Applied(_)
    ));

    for _ in 0..30 {
        let connect = process.apply(ReconnectEvent::TorAvailable, now_ms);
        let generation = match connect {
            ReconnectApply::Applied(actions) => actions
                .into_iter()
                .find_map(|action| match action {
                    ReconnectAction::ConnectRelay { generation } => Some(generation),
                    _ => None,
                })
                .expect("Tor availability should request one relay connection"),
            ReconnectApply::IgnoredStale => panic!("fresh Tor availability was ignored"),
        };

        let disconnected = process.apply(
            ReconnectEvent::RelayDisconnected {
                generation,
                reason: "simulated disconnect".to_owned(),
            },
            now_ms,
        );
        let retry_at_ms = match disconnected {
            ReconnectApply::Applied(actions) => actions
                .into_iter()
                .find_map(|action| match action {
                    ReconnectAction::ScheduleRetry { retry_at_ms, .. } => Some(retry_at_ms),
                    _ => None,
                })
                .expect("disconnect should schedule retry"),
            ReconnectApply::IgnoredStale => panic!("current disconnect was ignored"),
        };
        assert!(retry_at_ms >= now_ms);
        assert!(retry_at_ms - now_ms <= 300_000);
        assert!(matches!(process.state, ReconnectState::Backoff { .. }));

        now_ms = retry_at_ms;
        let retry = process.apply(ReconnectEvent::BackoffElapsed { generation }, now_ms);
        assert!(matches!(retry, ReconnectApply::Applied(_)));
        assert!(matches!(process.state, ReconnectState::Connecting { .. }));
    }

    let current_generation = process.generation;
    assert_eq!(
        process.apply(
            ReconnectEvent::RelayConnected {
                generation: current_generation.saturating_sub(1),
            },
            now_ms,
        ),
        ReconnectApply::IgnoredStale
    );
    assert!(!matches!(process.state, ReconnectState::Stopped));
}

#[test]
fn network_and_tor_loss_never_become_fatal_state() {
    let mut process = ReconnectProcess::default();
    process.apply(ReconnectEvent::TorAvailable, 0);

    let network_lost = process.apply(ReconnectEvent::NetworkLost, 1);
    assert_eq!(
        network_lost,
        ReconnectApply::Applied(vec![ReconnectAction::WaitForNetwork])
    );
    assert_eq!(process.state, ReconnectState::WaitingForNetwork);

    process.apply(ReconnectEvent::NetworkAvailable, 2);
    assert_eq!(process.state, ReconnectState::WaitingForTor);

    process.apply(ReconnectEvent::TorLost, 3);
    assert_eq!(process.state, ReconnectState::WaitingForTor);

    let reconnect = process.apply(ReconnectEvent::TorAvailable, 4);
    assert!(matches!(reconnect, ReconnectApply::Applied(_)));
    assert!(matches!(process.state, ReconnectState::Connecting { .. }));
}
