#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RelayWriterConfig {
    pub control_channel_capacity: usize,
    pub data_channel_capacity: usize,
}
