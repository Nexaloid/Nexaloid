use nexaloid_sys as sys;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};

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

    pub fn tokenize(&self, text: &str, mode: Mode) -> Result<Vec<Token>, Error> {
        let mut out = Vec::new();
        let mut ctx = CallbackCtx { text, out: &mut out };
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
