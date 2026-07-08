use std::ffi::{c_char, c_void};
use std::path::PathBuf;

pub fn bundled_dict_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("data")
        .join("dict")
        .join("nexaloid.nxdict")
}

pub fn bundled_hmm_artifact_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("data")
        .join("hmm")
        .join("bmes_hmm_wordhub_lattice.nxhmm")
}

#[repr(C)]
pub struct NxEngine {
    // Opaque native handle; Rust must never construct or inspect this value.
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NxStatus {
    Ok = 0,
    InvalidUtf8 = 1,
    OutOfMemory = 2,
    InvalidConfig = 3,
    Io = 4,
    Plugin = 5,
    Internal = 255,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NxMode {
    Accurate = 0,
    Full = 1,
    Search = 2,
    RecallSearch = 3,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct NxConfig {
    pub dict_path: *const c_char,
    pub user_dict_path: *const c_char,
    pub enable_hmm: u32,
    pub enable_normalization: u32,
    pub enable_plugins: u32,
    pub preserve_whitespace: u32,
    pub reserved: [u32; 7],
}

impl Default for NxConfig {
    fn default() -> Self {
        Self {
            dict_path: std::ptr::null(),
            user_dict_path: std::ptr::null(),
            enable_hmm: 0,
            enable_normalization: 0,
            enable_plugins: 0,
            preserve_whitespace: 0,
            reserved: [0; 7],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct NxToken {
    pub start_byte: u32,
    pub end_byte: u32,
    pub start_char: u32,
    pub end_char: u32,
    pub word_id: u32,
    pub pos_id: u16,
    pub source: u16,
    pub flags: u16,
    pub score: f32,
}

pub type NxTokenCallback = Option<
    unsafe extern "C" fn(
        token: *const NxToken,
        text: *const c_char,
        text_len: usize,
        user_data: *mut c_void,
    ),
>;

#[link(name = "nexaloid")]
extern "C" {
    // Raw C ABI declarations. Higher-level crates should use nexaloid instead of calling these directly.
    pub fn nx_engine_new(config: *const NxConfig, out_engine: *mut *mut NxEngine) -> NxStatus;
    pub fn nx_engine_free(engine: *mut NxEngine);
    pub fn nx_set_rule_config(
        engine: *mut NxEngine,
        enabled_mask: u32,
        scores: *const f32,
        score_count: usize,
    ) -> NxStatus;
    pub fn nx_load_rules_json(
        engine: *mut NxEngine,
        json: *const c_char,
        json_len: usize,
    ) -> NxStatus;
    pub fn nx_clear_rules(engine: *mut NxEngine) -> NxStatus;
    pub fn nx_tokenize(
        engine: *mut NxEngine,
        text: *const c_char,
        text_len: usize,
        mode: NxMode,
        callback: NxTokenCallback,
        user_data: *mut c_void,
    ) -> NxStatus;
    pub fn nx_load_plugin(
        engine: *mut NxEngine,
        plugin_path: *const c_char,
        config_json: *const c_char,
    ) -> NxStatus;
    pub fn nx_add_word(
        engine: *mut NxEngine,
        word: *const c_char,
        word_len: usize,
        word_id: u32,
        score: f32,
        pos_id: u16,
    ) -> NxStatus;
    pub fn nx_reload_user_dict(engine: *mut NxEngine, user_dict_path: *const c_char) -> NxStatus;
    pub fn nx_status_message(status: NxStatus) -> *const c_char;
}
