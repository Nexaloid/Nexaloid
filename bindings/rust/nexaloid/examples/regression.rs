use nexaloid::{bundled_hmm_artifact_path, Mode, Tokenizer};

fn main() -> Result<(), nexaloid::Error> {
    assert!(bundled_hmm_artifact_path().exists());
    let tokenizer = Tokenizer::new_default()?;
    let tokens = tokenizer.tokenize("南京市长江大桥", Mode::Accurate)?;
    for token in tokens {
        println!("{}", token.text);
    }
    Ok(())
}
