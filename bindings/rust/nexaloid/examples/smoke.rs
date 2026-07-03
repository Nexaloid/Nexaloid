use nexaloid::{Mode, Tokenizer};

fn main() -> Result<(), nexaloid::Error> {
    let tokenizer = Tokenizer::new_default()?;
    let tokens = tokenizer.tokenize("南京市长江大桥", Mode::Accurate)?;
    for token in tokens {
        println!("{}", token.text);
    }
    Ok(())
}
