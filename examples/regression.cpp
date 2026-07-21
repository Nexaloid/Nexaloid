#include <atomic>
#include <cstdlib>
#include <iostream>
#include <new>
#include <stdexcept>
#include <vector>

#include <nexaloid.hpp>

namespace {
std::atomic<bool> fail_next_allocation{false};
}

void* operator new(std::size_t size) {
    if (fail_next_allocation.exchange(false)) {
        throw std::bad_alloc();
    }
    if (void* allocation = std::malloc(size)) {
        return allocation;
    }
    throw std::bad_alloc();
}

void operator delete(void* allocation) noexcept {
    std::free(allocation);
}

void operator delete(void* allocation, std::size_t) noexcept {
    std::free(allocation);
}

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
    expect(tokenizer, "文档 秒", {"文档", "秒"});

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
    if (tokenizer.cut("研究生命起源", nexaloid::Mode::Search) != std::vector<std::string>{"研究", "生命", "起源"}) {
        throw std::runtime_error("search emitted cross-boundary noise");
    }
    bool recall_saw_student = false;
    for (const auto& token : tokenizer.tokenize("研究生命起源", nexaloid::Mode::RecallSearch)) {
        if (token.text == "研究生") {
            recall_saw_student = true;
        }
    }
    if (!recall_saw_student) {
        throw std::runtime_error("recall search missing cross-boundary candidate");
    }

    bool saw_callback_allocation_failure = false;
    fail_next_allocation = true;
    try {
        static_cast<void>(tokenizer.tokenize("南京市长江大桥"));
    } catch (const std::bad_alloc&) {
        saw_callback_allocation_failure = true;
    }
    if (!saw_callback_allocation_failure) {
        throw std::runtime_error("callback allocation failure was not rethrown");
    }

    tokenizer.load_rules_json(R"({"version":1,"rules":[{"name":"stock","kind":"prefixed_number","prefixes":["SH"],"digits":{"min":6,"max":6},"score":80}]})");
    bool saw_stock = false;
    for (const auto& token : tokenizer.tokenize("买SH600519")) {
        if (token.text == "SH600519" &&
            token.source == nexaloid::Source::Rule &&
            std::string_view(nexaloid::source_name(token.source)) == "rule" &&
            token.flags == 1) {
            saw_stock = true;
        }
    }
    if (!saw_stock) {
        throw std::runtime_error("missing custom rule token");
    }
    tokenizer.clear_rules();

    config.preserve_whitespace = 1;
    nexaloid::Tokenizer preserve_tokenizer(config);
    expect(preserve_tokenizer, "文档 秒", {"文档", " ", "秒"});

    std::cout << "cpp regression passed\n";
    return 0;
}
