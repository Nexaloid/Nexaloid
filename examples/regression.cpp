#include <iostream>
#include <stdexcept>
#include <vector>

#include <nexaloid.hpp>

void expect(nexaloid::Tokenizer& tokenizer, std::string_view text, const std::vector<std::string>& expected) {
    auto words = tokenizer.cut(text);
    if (words != expected) {
        throw std::runtime_error("unexpected tokens");
    }
}

int main() {
    NxConfig config{};
    config.dict_path = "data/dict/nexaloid.tsv";

    nexaloid::Tokenizer tokenizer(config);
    expect(tokenizer, "南京市长江大桥", {"南京市", "长江大桥"});
    expect(tokenizer, "我们在日本东京做RAG中文检索实验", {"我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验"});
    expect(tokenizer, "我爱北京天安门", {"我", "爱", "北京", "天安门"});
    expect(tokenizer, "长春市长春节前发表讲话", {"长春", "市长", "春节前", "发表", "讲话"});

    bool saw_ascii = false;
    for (const auto& token : tokenizer.tokenize("ChatGPT-5.5支持中文RAG检索。", nexaloid::Mode::Search)) {
        if (token.text == "Ch" || token.text == "Cha" || token.text == "ha") {
            throw std::runtime_error("unexpected ascii search ngram");
        }
        if (token.text == "ChatGPT-5.5") {
            saw_ascii = true;
        }
    }
    if (!saw_ascii) {
        throw std::runtime_error("missing ascii search token");
    }
    std::cout << "cpp regression passed\n";
    return 0;
}
