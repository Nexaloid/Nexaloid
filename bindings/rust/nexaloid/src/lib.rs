use nexaloid_sys as sys;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::path::{Path, PathBuf};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn bundled_hmm_artifact_path() -> std::path::PathBuf {
    sys::bundled_hmm_artifact_path()
}

pub fn bundled_hmm_plugin_path() -> std::path::PathBuf {
    sys::bundled_hmm_plugin_path()
}

pub fn bundled_entity_artifact_path() -> std::path::PathBuf {
    sys::bundled_data_path("entity/entity_bmes_perceptron.nxbmes")
}

pub fn bundled_entity_plugin_path() -> std::path::PathBuf {
    sys::bundled_entity_plugin_path()
}

#[derive(Debug)]
pub struct Error {
    pub status: sys::NxStatus,
    pub message: String,
}

fn compatibility_error(message: String) -> Error {
    Error {
        status: sys::NxStatus::InvalidConfig,
        message,
    }
}

pub fn runtime_version() -> Result<String, Error> {
    runtime_version_from_ptr(sys::runtime_version_ptr())
}

fn runtime_version_from_ptr(pointer: *const c_char) -> Result<String, Error> {
    if pointer.is_null() {
        return Err(compatibility_error(
            "native runtime is missing nx_runtime_version; found an outdated Nexaloid library"
                .to_string(),
        ));
    }
    let version = unsafe { CStr::from_ptr(pointer) }.to_str().map_err(|_| {
        compatibility_error("native runtime returned an invalid version".to_string())
    })?;
    Ok(version.to_string())
}

fn check_component_version(component: &str, expected: &str, actual: &str) -> Result<(), Error> {
    if expected == actual {
        return Ok(());
    }
    Err(compatibility_error(format!(
        "{component} version mismatch: expected {expected}, found {actual}"
    )))
}

fn ensure_runtime_compatible() -> Result<(), Error> {
    check_component_version("nexaloid-sys crate", VERSION, sys::VERSION)?;
    check_component_version("native runtime", VERSION, &runtime_version()?)
}

#[derive(Clone, Copy)]
pub enum Mode {
    Accurate,
    Full,
    Search,
    RecallSearch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum Source {
    BaseDict,
    UserDict,
    DomainDict,
    Rule,
    Unknown,
    Plugin,
    Unrecognized(u16),
}

impl Source {
    pub const fn from_raw(value: u16) -> Self {
        match value {
            1 => Self::BaseDict,
            2 => Self::UserDict,
            3 => Self::DomainDict,
            4 => Self::Rule,
            5 => Self::Unknown,
            6 => Self::Plugin,
            value => Self::Unrecognized(value),
        }
    }

    pub const fn raw(self) -> u16 {
        match self {
            Self::BaseDict => 1,
            Self::UserDict => 2,
            Self::DomainDict => 3,
            Self::Rule => 4,
            Self::Unknown => 5,
            Self::Plugin => 6,
            Self::Unrecognized(value) => value,
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::BaseDict => "base_dict",
            Self::UserDict => "user_dict",
            Self::DomainDict => "domain_dict",
            Self::Rule => "rule",
            Self::Unknown => "unknown",
            Self::Plugin => "plugin",
            Self::Unrecognized(_) => "unrecognized",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Token {
    pub text: String,
    pub start_byte: u32,
    pub end_byte: u32,
    pub start_char: u32,
    pub end_char: u32,
    pub word_id: u32,
    pub pos_id: u16,
    pub source: Source,
    pub flags: u16,
    pub score: f32,
}

impl Token {
    /// Returns the custom rule's 1-based JSON array index.
    pub const fn custom_rule_index(&self) -> Option<u16> {
        if matches!(self.source, Source::Rule) && self.flags != 0 {
            Some(self.flags)
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Config {
    dict_path: Option<PathBuf>,
    user_dict_path: Option<PathBuf>,
    preserve_whitespace: bool,
}

impl Config {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn dict_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.dict_path = Some(path.into());
        self
    }

    pub fn user_dict_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.user_dict_path = Some(path.into());
        self
    }

    pub fn preserve_whitespace(mut self, preserve: bool) -> Self {
        self.preserve_whitespace = preserve;
        self
    }
}

pub struct Tokenizer {
    // Safe wrapper around the opaque C engine pointer.
    engine: *mut sys::NxEngine,
}

impl Tokenizer {
    pub fn new_default() -> Result<Self, Error> {
        Self::new_default_with_whitespace(false)
    }

    pub fn new_default_with_whitespace(preserve_whitespace: bool) -> Result<Self, Error> {
        let config = Config::new()
            .dict_path(sys::bundled_dict_path())
            .preserve_whitespace(preserve_whitespace);
        Self::new(&config)
    }

    pub fn new(config: &Config) -> Result<Self, Error> {
        let dict_path = config
            .dict_path
            .as_deref()
            .map(|path| path_to_cstring("dict_path", path))
            .transpose()?;
        let user_dict_path = config
            .user_dict_path
            .as_deref()
            .map(|path| path_to_cstring("user_dict_path", path))
            .transpose()?;
        let raw = sys::NxConfig {
            dict_path: dict_path
                .as_ref()
                .map_or(std::ptr::null(), |path| path.as_ptr()),
            user_dict_path: user_dict_path
                .as_ref()
                .map_or(std::ptr::null(), |path| path.as_ptr()),
            preserve_whitespace: u32::from(config.preserve_whitespace),
            ..Default::default()
        };
        // SAFETY: both optional C strings remain alive for the synchronous constructor call.
        unsafe { Self::from_raw_config(raw) }
    }

    /// Creates a tokenizer from the low-level C ABI configuration.
    ///
    /// # Safety
    ///
    /// Every non-null pointer in `config` must reference a valid NUL-terminated string for the
    /// duration of this call. Reserved fields must satisfy the current C ABI contract.
    ///
    /// ```compile_fail
    /// use nexaloid::Tokenizer;
    ///
    /// let raw = nexaloid_sys::NxConfig::default();
    /// let _ = Tokenizer::from_raw_config(raw);
    /// ```
    pub unsafe fn from_raw_config(config: sys::NxConfig) -> Result<Self, Error> {
        ensure_runtime_compatible()?;
        let mut engine = std::ptr::null_mut();
        check(unsafe { sys::nx_engine_new(&config, &mut engine) })?;
        Ok(Self { engine })
    }

    pub fn add_word(&mut self, word: &str, score: f32) -> Result<(), Error> {
        check(unsafe {
            sys::nx_add_word(
                self.engine,
                word.as_ptr() as *const c_char,
                word.len(),
                0,
                score,
                0,
            )
        })
    }

    pub fn load_userdict(&mut self, path: &str) -> Result<(), Error> {
        let path = CString::new(path).map_err(|_| Error {
            status: sys::NxStatus::InvalidConfig,
            message: "path contains NUL".to_string(),
        })?;
        check(unsafe { sys::nx_reload_user_dict(self.engine, path.as_ptr()) })
    }

    pub fn load_plugin(&mut self, path: &str, config_json: Option<&str>) -> Result<(), Error> {
        let path = CString::new(path).map_err(|_| Error {
            status: sys::NxStatus::InvalidConfig,
            message: "path contains NUL".to_string(),
        })?;
        let config = match config_json {
            Some(value) => Some(CString::new(value).map_err(|_| Error {
                status: sys::NxStatus::InvalidConfig,
                message: "config_json contains NUL".to_string(),
            })?),
            None => None,
        };
        check(unsafe {
            sys::nx_load_plugin(
                self.engine,
                path.as_ptr(),
                config
                    .as_ref()
                    .map_or(std::ptr::null(), |value| value.as_ptr()),
            )
        })
    }

    pub fn load_plugins<P: AsRef<Path>>(
        &mut self,
        dir: P,
        config_json: Option<&str>,
    ) -> Result<(), Error> {
        let ext = if cfg!(windows) {
            "dll"
        } else if cfg!(target_os = "macos") {
            "dylib"
        } else {
            "so"
        };
        let mut paths = std::fs::read_dir(dir)
            .map_err(|err| Error {
                status: sys::NxStatus::Io,
                message: err.to_string(),
            })?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.is_file()
                    && path
                        .file_name()
                        .and_then(|value| value.to_str())
                        .is_some_and(|name| name.starts_with("nexaloid_plugin"))
                    && path.extension().and_then(|value| value.to_str()) == Some(ext)
            })
            .collect::<Vec<_>>();
        paths.sort();
        for path in paths {
            let path = path.to_string_lossy();
            self.load_plugin(&path, config_json)?;
        }
        Ok(())
    }

    pub fn load_rules_json(&mut self, json: &str) -> Result<(), Error> {
        check(unsafe {
            sys::nx_load_rules_json(self.engine, json.as_ptr() as *const c_char, json.len())
        })
    }

    pub fn load_rules<P: AsRef<Path>>(&mut self, path: P) -> Result<(), Error> {
        let json = std::fs::read_to_string(path).map_err(|err| Error {
            status: sys::NxStatus::Io,
            message: err.to_string(),
        })?;
        self.load_rules_json(&json)
    }

    pub fn clear_rules(&mut self) -> Result<(), Error> {
        check(unsafe { sys::nx_clear_rules(self.engine) })
    }

    pub fn tokenize(&self, text: &str, mode: Mode) -> Result<Vec<Token>, Error> {
        let mut out = Vec::new();
        let mut ctx = CallbackCtx {
            text,
            out: &mut out,
        };
        // nx_tokenize invokes the callback before it returns, so borrowing ctx is safe.
        check(unsafe {
            sys::nx_tokenize(
                self.engine,
                text.as_ptr() as *const c_char,
                text.len(),
                mode.into(),
                Some(on_token),
                &mut ctx as *mut _ as *mut c_void,
            )
        })?;
        Ok(out)
    }
}

fn path_to_cstring(field: &str, path: &Path) -> Result<CString, Error> {
    let value = path.to_str().ok_or_else(|| Error {
        status: sys::NxStatus::InvalidConfig,
        message: format!("{field} is not valid UTF-8"),
    })?;
    CString::new(value).map_err(|_| Error {
        status: sys::NxStatus::InvalidConfig,
        message: format!("{field} contains NUL"),
    })
}

impl Drop for Tokenizer {
    fn drop(&mut self) {
        unsafe { sys::nx_engine_free(self.engine) };
    }
}

impl From<Mode> for sys::NxMode {
    fn from(value: Mode) -> Self {
        match value {
            Mode::Accurate => sys::NxMode::Accurate,
            Mode::Full => sys::NxMode::Full,
            Mode::Search => sys::NxMode::Search,
            Mode::RecallSearch => sys::NxMode::RecallSearch,
        }
    }
}

struct CallbackCtx<'a> {
    // Keep the original Rust str so byte offsets can slice without copying callback text.
    text: &'a str,
    out: &'a mut Vec<Token>,
}

unsafe extern "C" fn on_token(
    token: *const sys::NxToken,
    _text: *const c_char,
    _text_len: usize,
    user_data: *mut c_void,
) {
    let token = *token;
    let ctx = &mut *(user_data as *mut CallbackCtx<'_>);
    let start = token.start_byte as usize;
    let end = token.end_byte as usize;
    // Core guarantees token byte offsets are UTF-8 boundaries for the original input.
    ctx.out.push(Token {
        text: ctx.text[start..end].to_string(),
        start_byte: token.start_byte,
        end_byte: token.end_byte,
        start_char: token.start_char,
        end_char: token.end_char,
        word_id: token.word_id,
        pos_id: token.pos_id,
        source: Source::from_raw(token.source),
        flags: token.flags,
        score: token.score,
    });
}

fn check(status: sys::NxStatus) -> Result<(), Error> {
    if status == sys::NxStatus::Ok {
        return Ok(());
    }
    let message = unsafe {
        CStr::from_ptr(sys::nx_status_message(status))
            .to_string_lossy()
            .into_owned()
    };
    Err(Error { status, message })
}

#[cfg(test)]
mod tests {
    use super::{
        bundled_entity_artifact_path, bundled_entity_plugin_path, bundled_hmm_artifact_path,
        bundled_hmm_plugin_path, check_component_version, runtime_version,
        runtime_version_from_ptr, Mode, Source, Tokenizer, VERSION,
    };

    fn texts(tokens: Vec<super::Token>) -> Vec<String> {
        tokens.into_iter().map(|token| token.text).collect()
    }

    #[test]
    fn runtime_version_matches_crate() {
        assert_eq!(runtime_version().unwrap(), VERSION);
        let missing = runtime_version_from_ptr(std::ptr::null())
            .expect_err("missing runtime version symbol must fail");
        assert!(missing.message.contains("outdated Nexaloid library"));
        let error = check_component_version("native runtime", VERSION, "0.0.0-old")
            .expect_err("mismatched runtime must fail");
        assert!(error.message.contains("version mismatch"));
    }

    #[test]
    fn regression_cases() {
        let tokenizer = Tokenizer::new_default().unwrap();
        let cases = [
            ("南京市长江大桥", vec!["南京市", "长江大桥"]),
            (
                "我们在日本东京做RAG中文检索实验",
                vec![
                    "我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验",
                ],
            ),
            ("我爱北京天安门", vec!["我", "爱", "北京", "天安门"]),
            (
                "长春市长春节前发表讲话",
                vec!["长春", "市长", "春节前", "发表", "讲话"],
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(
                texts(tokenizer.tokenize(text, Mode::Accurate).unwrap()),
                expected
            );
        }

        assert_eq!(
            texts(tokenizer.tokenize("文档 秒", Mode::Accurate).unwrap()),
            vec!["文档", "秒"]
        );
        let tokenizer = Tokenizer::new_default_with_whitespace(true).unwrap();
        assert_eq!(
            texts(tokenizer.tokenize("文档 秒", Mode::Accurate).unwrap()),
            vec!["文档", " ", "秒"]
        );

        let search = texts(
            tokenizer
                .tokenize("ChatGPT-5.5支持中文RAG检索。", Mode::Search)
                .unwrap(),
        );
        for word in ["ChatGPT-5.5", "中文", "RAG", "检索"] {
            assert!(
                search.iter().any(|item| item == word),
                "missing {word}: {search:?}"
            );
        }
        for word in ["Ch", "Cha", "ha"] {
            assert!(
                !search.iter().any(|item| item == word),
                "unexpected {word}: {search:?}"
            );
        }

        let search = texts(tokenizer.tokenize("研究生命起源", Mode::Search).unwrap());
        assert!(!search.iter().any(|item| item == "研究生"));
        let recall = texts(
            tokenizer
                .tokenize("研究生命起源", Mode::RecallSearch)
                .unwrap(),
        );
        assert!(recall.iter().any(|item| item == "研究生"));
    }

    #[test]
    fn custom_rules() {
        let mut tokenizer = Tokenizer::new_default().unwrap();
        tokenizer
            .load_rules_json(
                r#"{"version":1,"rules":[{"name":"stock","kind":"prefixed_number","prefixes":["SH"],"digits":{"min":6,"max":6},"score":80}]}"#,
            )
            .unwrap();
        let tokens = tokenizer.tokenize("买SH600519", Mode::Accurate).unwrap();
        let token = tokens
            .iter()
            .find(|token| token.text == "SH600519")
            .expect("missing custom rule token");
        assert_eq!(token.source, Source::Rule);
        assert_eq!(token.source.as_str(), "rule");
        assert_eq!(token.flags, 1);
        assert_eq!(token.custom_rule_index(), Some(1));
        assert_eq!(Source::from_raw(99), Source::Unrecognized(99));
        tokenizer.clear_rules().unwrap();
    }

    #[test]
    fn bundled_plugins_load_when_required() {
        if std::env::var_os("NEXALOID_REQUIRE_BUNDLED_PLUGINS").is_none() {
            return;
        }

        let hmm_plugin = bundled_hmm_plugin_path();
        let entity_plugin = bundled_entity_plugin_path();
        assert!(hmm_plugin.is_file(), "missing {}", hmm_plugin.display());
        assert!(
            entity_plugin.is_file(),
            "missing {}",
            entity_plugin.display()
        );

        let mut hmm = Tokenizer::new_default().unwrap();
        let hmm_plugin = hmm_plugin.to_string_lossy();
        let hmm_artifact = bundled_hmm_artifact_path();
        let hmm_artifact = hmm_artifact.to_string_lossy();
        hmm.load_plugin(&hmm_plugin, Some(&hmm_artifact)).unwrap();
        assert_eq!(
            texts(hmm.tokenize("并参与杭算项目", Mode::Accurate).unwrap()),
            vec!["并", "参与", "杭算", "项目"]
        );

        let mut entity = Tokenizer::new_default().unwrap();
        let entity_plugin = entity_plugin.to_string_lossy();
        let entity_artifact = bundled_entity_artifact_path()
            .to_string_lossy()
            .replace('\\', "/");
        let config = format!(r#"{{"artifact":"{entity_artifact}"}}"#);
        entity.load_plugin(&entity_plugin, Some(&config)).unwrap();
        assert!(entity
            .tokenize("欧盟委员会", Mode::Accurate)
            .unwrap()
            .iter()
            .any(|token| token.text == "欧盟委员会" && token.source == Source::Plugin));
    }
}
