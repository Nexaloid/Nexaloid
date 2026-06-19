const { Tokenizer } = require("..");

const tokenizer = new Tokenizer();
const words = tokenizer.lcut("南京市长江大桥");
console.log(words.join("/"));

if (words.join("/") !== "南京市/长江大桥") {
  throw new Error(`unexpected tokens: ${words.join("/")}`);
}

tokenizer.close();
