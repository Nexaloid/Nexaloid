package nexaloid

import "testing"

func TestTokenize(t *testing.T) {
	tokenizer, err := New("../../../data/dict/nexaloid.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer tokenizer.Close()

	tokens, err := tokenizer.Tokenize("南京市长江大桥", Accurate)
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens) != 2 {
		t.Fatalf("expected 2 tokens, got %d: %#v", len(tokens), tokens)
	}
	if tokens[0].Text != "南京市" || tokens[1].Text != "长江大桥" {
		t.Fatalf("unexpected tokens: %#v", tokens)
	}
}

func TestPreserveWhitespace(t *testing.T) {
	tokenizer, err := New("../../../data/dict/nexaloid.tsv")
	if err != nil {
		t.Fatal(err)
	}
	filtered, err := tokenizer.Tokenize("文档 秒", Accurate)
	tokenizer.Close()
	if err != nil {
		t.Fatal(err)
	}
	if got := tokenTexts(filtered); !sameStrings(got, []string{"文档", "秒"}) {
		t.Fatalf("unexpected default whitespace tokens: %#v", got)
	}

	tokenizer, err = NewWithOptions(Options{DictPath: "../../../data/dict/nexaloid.tsv", PreserveWhitespace: true})
	if err != nil {
		t.Fatal(err)
	}
	defer tokenizer.Close()
	preserved, err := tokenizer.Tokenize("文档 秒", Accurate)
	if err != nil {
		t.Fatal(err)
	}
	if got := tokenTexts(preserved); !sameStrings(got, []string{"文档", " ", "秒"}) {
		t.Fatalf("unexpected preserved whitespace tokens: %#v", got)
	}
}

func TestRegressionCases(t *testing.T) {
	tokenizer, err := New("../../../data/dict/nexaloid.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer tokenizer.Close()

	cases := map[string][]string{
		"我们在日本东京做RAG中文检索实验": {"我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验"},
		"我爱北京天安门":           {"我", "爱", "北京", "天安门"},
		"长春市长春节前发表讲话":       {"长春", "市长", "春节前", "发表", "讲话"},
	}
	for text, expected := range cases {
		tokens, err := tokenizer.Tokenize(text, Accurate)
		if err != nil {
			t.Fatal(err)
		}
		if got := tokenTexts(tokens); !sameStrings(got, expected) {
			t.Fatalf("%s: expected %#v, got %#v", text, expected, got)
		}
	}

	search, err := tokenizer.Tokenize("ChatGPT-5.5支持中文RAG检索。", Search)
	if err != nil {
		t.Fatal(err)
	}
	got := tokenTexts(search)
	if contains(got, "Ch") || contains(got, "Cha") || contains(got, "ha") {
		t.Fatalf("unexpected ASCII ngrams: %#v", got)
	}
	for _, word := range []string{"ChatGPT-5.5", "中文", "RAG", "检索"} {
		if !contains(got, word) {
			t.Fatalf("missing %q in %#v", word, got)
		}
	}

	search, err = tokenizer.Tokenize("研究生命起源", Search)
	if err != nil {
		t.Fatal(err)
	}
	if contains(tokenTexts(search), "研究生") {
		t.Fatalf("search emitted cross-boundary noise: %#v", search)
	}
	recall, err := tokenizer.Tokenize("研究生命起源", RecallSearch)
	if err != nil {
		t.Fatal(err)
	}
	if !contains(tokenTexts(recall), "研究生") {
		t.Fatalf("recall search missing candidate: %#v", recall)
	}
}

func TestCustomRules(t *testing.T) {
	tokenizer, err := New("../../../data/dict/nexaloid.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer tokenizer.Close()

	if err := tokenizer.LoadRulesJSON(`{"version":1,"rules":[{"name":"stock","kind":"prefixed_number","prefixes":["SH"],"digits":{"min":6,"max":6},"score":80}]}`); err != nil {
		t.Fatal(err)
	}
	tokens, err := tokenizer.Tokenize("买SH600519", Accurate)
	if err != nil {
		t.Fatal(err)
	}
	if !contains(tokenTexts(tokens), "SH600519") {
		t.Fatalf("missing custom rule token: %#v", tokens)
	}
	if err := tokenizer.ClearRules(); err != nil {
		t.Fatal(err)
	}
}

func tokenTexts(tokens []Token) []string {
	out := make([]string, len(tokens))
	for i, token := range tokens {
		out[i] = token.Text
	}
	return out
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func contains(items []string, needle string) bool {
	for _, item := range items {
		if item == needle {
			return true
		}
	}
	return false
}
