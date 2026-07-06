use nexaloid_sys as sys;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::path::Path;

#[derive(Debug)]
pub struct Error {
    pub status: sys::NxStatus,
    pub message: String,
}

#[derive(Clone, Copy)]
pub enum Mode {
    Accurate,
    Full,
    Search,
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
    pub source: u16,
    pub score: f32,
}

pub struct Tokenizer {
    // Safe wrapper around the opaque C engine pointer.
    engine: *mut sys::NxEngine,
}

impl Tokenizer {
    pub fn new_default() -> Result<Self, Error> {
        let dict =
            CString::new(sys::bundled_dict_path().to_string_lossy().as_bytes()).map_err(|_| {
                Error {
                    status: sys::NxStatus::InvalidConfig,
                    message: "bundled dictionary path contains NUL".to_string(),
                }
            })?;
        let config = sys::NxConfig {
            dict_path: dict.as_ptr(),
            ..Default::default()
        };
        Self::new(config)
    }

    pub fn new(config: sys::NxConfig) -> Result<Self, Error> {
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
        source: token.source,
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
    use super::{Mode, Tokenizer};

    fn texts(tokens: Vec<super::Token>) -> Vec<String> {
        tokens.into_iter().map(|token| token.text).collect()
    }

    #[test]
    fn regression_cases() {
        let tokenizer = Tokenizer::new_default().unwrap();
        let cases = [
            (
                "南京市长江大桥",
                vec!["南京市", "长江大桥"],
            ),
            (
                "我们在日本东京做RAG中文检索实验",
                vec!["我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验"],
            ),
            ("我爱北京天安门", vec!["我", "爱", "北京", "天安门"]),
            (
                "长春市长春节前发表讲话",
                vec!["长春", "市长", "春节前", "发表", "讲话"],
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(texts(tokenizer.tokenize(text, Mode::Accurate).unwrap()), expected);
        }

        let search = texts(tokenizer.tokenize("ChatGPT-5.5支持中文RAG检索。", Mode::Search).unwrap());
        for word in ["ChatGPT-5.5", "中文", "RAG", "检索"] {
            assert!(search.iter().any(|item| item == word), "missing {word}: {search:?}");
        }
        for word in ["Ch", "Cha", "ha"] {
            assert!(!search.iter().any(|item| item == word), "unexpected {word}: {search:?}");
        }
    }
}
