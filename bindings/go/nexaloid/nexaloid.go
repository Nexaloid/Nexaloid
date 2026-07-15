package nexaloid

/*
#cgo CFLAGS: -I../../../core/include
#cgo windows LDFLAGS: -L../../../core/zig-out/lib -lnexaloid
#cgo linux darwin LDFLAGS: -L../../../core/zig-out/lib -lnexaloid
#include <stdlib.h>
#include "nexaloid.h"

extern void nxGoTokenCallback(NxToken* token, char* text, size_t text_len, void* user_data);

static inline NxStatus nx_go_tokenize(NxEngine* engine, const char* text, size_t text_len, NxMode mode, void* user_data) {
	return nx_tokenize(engine, text, text_len, mode, (NxTokenCallback)nxGoTokenCallback, user_data);
}
*/
import "C"

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"unsafe"
)

type Mode int

const (
	Accurate     Mode = C.NX_MODE_ACCURATE
	Full         Mode = C.NX_MODE_FULL
	Search       Mode = C.NX_MODE_SEARCH
	RecallSearch Mode = C.NX_MODE_RECALL_SEARCH
)

type Source uint16

const (
	SourceBaseDict   Source = C.NX_SOURCE_BASE_DICT
	SourceUserDict   Source = C.NX_SOURCE_USER_DICT
	SourceDomainDict Source = C.NX_SOURCE_DOMAIN_DICT
	SourceRule       Source = C.NX_SOURCE_RULE
	SourceUnknown    Source = C.NX_SOURCE_UNKNOWN
	SourcePlugin     Source = C.NX_SOURCE_PLUGIN
)

func (source Source) String() string {
	switch source {
	case SourceBaseDict:
		return "base_dict"
	case SourceUserDict:
		return "user_dict"
	case SourceDomainDict:
		return "domain_dict"
	case SourceRule:
		return "rule"
	case SourceUnknown:
		return "unknown"
	case SourcePlugin:
		return "plugin"
	default:
		return "unrecognized"
	}
}

type Token struct {
	Text      string
	StartByte uint32
	EndByte   uint32
	StartChar uint32
	EndChar   uint32
	WordID    uint32
	PosID     uint16
	Source    Source
	Flags     uint16
	Score     float32
}

func (token Token) CustomRuleIndex() (uint16, bool) {
	return token.Flags, token.Source == SourceRule && token.Flags != 0
}

type Tokenizer struct {
	// Opaque native engine handle owned by this Go wrapper.
	engine *C.NxEngine
}

type Options struct {
	DictPath           string
	PreserveWhitespace bool
}

func New(dictPath string) (*Tokenizer, error) {
	return NewWithOptions(Options{DictPath: dictPath})
}

func NewWithOptions(options Options) (*Tokenizer, error) {
	var cfg C.NxConfig
	var cDict *C.char
	if options.DictPath != "" {
		cDict = C.CString(options.DictPath)
		defer C.free(unsafe.Pointer(cDict))
		cfg.dict_path = cDict
	}
	if options.PreserveWhitespace {
		cfg.preserve_whitespace = 1
	}
	var engine *C.NxEngine
	if status := C.nx_engine_new(&cfg, &engine); status != C.NX_OK {
		return nil, statusError(status)
	}
	return &Tokenizer{engine: engine}, nil
}

func (t *Tokenizer) Close() {
	if t.engine != nil {
		C.nx_engine_free(t.engine)
		t.engine = nil
	}
}

func (t *Tokenizer) AddWord(word string, score float32) error {
	cWord := C.CString(word)
	defer C.free(unsafe.Pointer(cWord))
	if status := C.nx_add_word(t.engine, cWord, C.size_t(len([]byte(word))), 0, C.float(score), 0); status != C.NX_OK {
		return statusError(status)
	}
	return nil
}

func (t *Tokenizer) LoadPlugin(path string, configJSON string) error {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	var cConfig *C.char
	if configJSON != "" {
		cConfig = C.CString(configJSON)
		defer C.free(unsafe.Pointer(cConfig))
	}
	if status := C.nx_load_plugin(t.engine, cPath, cConfig); status != C.NX_OK {
		return statusError(status)
	}
	return nil
}

func (t *Tokenizer) LoadRulesJSON(jsonText string) error {
	cJSON := C.CString(jsonText)
	defer C.free(unsafe.Pointer(cJSON))
	if status := C.nx_load_rules_json(t.engine, cJSON, C.size_t(len([]byte(jsonText)))); status != C.NX_OK {
		return statusError(status)
	}
	return nil
}

func (t *Tokenizer) LoadRules(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return t.LoadRulesJSON(string(data))
}

func (t *Tokenizer) ClearRules() error {
	if status := C.nx_clear_rules(t.engine); status != C.NX_OK {
		return statusError(status)
	}
	return nil
}

func (t *Tokenizer) LoadPlugins(dir string, configJSON string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	ext := ".so"
	if runtime.GOOS == "windows" {
		ext = ".dll"
	} else if runtime.GOOS == "darwin" {
		ext = ".dylib"
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if !entry.Type().IsRegular() || !strings.HasPrefix(name, "nexaloid_plugin") || !strings.HasSuffix(name, ext) {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if err := t.LoadPlugin(filepath.Join(dir, name), configJSON); err != nil {
			return err
		}
	}
	return nil
}

func (t *Tokenizer) Tokenize(text string, mode Mode) ([]Token, error) {
	cText := C.CString(text)
	defer C.free(unsafe.Pointer(cText))
	ctx := callbackContext{text: text}
	// nx_go_tokenize calls back synchronously, so passing a pointer to ctx is safe for this call.
	if status := C.nx_go_tokenize(t.engine, cText, C.size_t(len([]byte(text))), C.NxMode(mode), unsafe.Pointer(&ctx)); status != C.NX_OK {
		return nil, statusError(status)
	}
	return ctx.tokens, nil
}

type callbackContext struct {
	// Keep the original Go string so token byte offsets can slice it without using C memory.
	text   string
	tokens []Token
}

//export nxGoTokenCallback
func nxGoTokenCallback(token *C.NxToken, text *C.char, textLen C.size_t, userData unsafe.Pointer) {
	_ = text
	_ = textLen
	ctx := (*callbackContext)(userData)
	start := int(token.start_byte)
	end := int(token.end_byte)
	// Core emits byte offsets on UTF-8 boundaries for the original input.
	ctx.tokens = append(ctx.tokens, Token{
		Text:      ctx.text[start:end],
		StartByte: uint32(token.start_byte),
		EndByte:   uint32(token.end_byte),
		StartChar: uint32(token.start_char),
		EndChar:   uint32(token.end_char),
		WordID:    uint32(token.word_id),
		PosID:     uint16(token.pos_id),
		Source:    Source(token.source),
		Flags:     uint16(token.flags),
		Score:     float32(token.score),
	})
}

func statusError(status C.NxStatus) error {
	return errors.New(C.GoString(C.nx_status_message(status)))
}
