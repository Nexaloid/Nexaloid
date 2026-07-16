use std::ffi::{c_char, c_void};
use std::path::{Path, PathBuf};

fn executable_file(relative: impl AsRef<Path>) -> PathBuf {
    let relative = relative.as_ref();
    let Some(parent) = std::env::current_exe()
        .ok()
        .and_then(|executable| executable.parent().map(Path::to_path_buf))
    else {
        return relative.to_path_buf();
    };
    let direct = parent.join(relative);
    if direct.is_file() {
        return direct;
    }
    let cargo_subdir = parent
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| matches!(name, "deps" | "examples" | "benches"));
    if cargo_subdir {
        if let Some(profile) = parent.parent() {
            let staged = profile.join(relative);
            if staged.is_file() {
                return staged;
            }
        }
    }
    direct
}

fn core_library_name() -> &'static str {
    if cfg!(windows) {
        "nexaloid.dll"
    } else if cfg!(target_os = "macos") {
        "libnexaloid.dylib"
    } else {
        "libnexaloid.so"
    }
}

pub fn bundled_dict_path() -> PathBuf {
    bundled_data_path("dict/nexaloid.nxdict")
}

pub fn bundled_hmm_artifact_path() -> PathBuf {
    bundled_data_path("hmm/bmes_hmm_wordhub_lattice.nxhmm")
}

pub fn bundled_data_path(relative: impl AsRef<Path>) -> PathBuf {
    executable_file(Path::new("nexaloid-data").join(relative))
}

pub fn bundled_native_dir() -> PathBuf {
    executable_file(core_library_name())
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
}

fn bundled_plugin_path(stem: &str) -> PathBuf {
    let extension = if cfg!(windows) {
        "dll"
    } else if cfg!(target_os = "macos") {
        "dylib"
    } else {
        "so"
    };
    let name = format!("nexaloid_plugin_{stem}.{extension}");
    executable_file(name)
}

pub fn bundled_hmm_plugin_path() -> PathBuf {
    bundled_plugin_path("hmm_lattice")
}

pub fn bundled_entity_plugin_path() -> PathBuf {
    bundled_plugin_path("entity_bmes")
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
