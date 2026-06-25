use nexaloid::{Mode, Tokenizer};
use nexaloid_sys::NxConfig;
use std::ffi::CString;

fn main() -> Result<(), nexaloid::Error> {
    let dict = CString::new("data/dict/nexaloid.tsv").unwrap();
    let mut config = NxConfig::default();
    config.dict_path = dict.as_ptr();

    let tokenizer = Tokenizer::new(config)?;
    let tokens = tokenizer.tokenize("南京市长江大桥", Mode::Accurate)?;
    for token in tokens {
        println!("{}", token.text);
    }
    Ok(())
}

