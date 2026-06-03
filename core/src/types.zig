// Character classes are scanner output consumed by matcher, rules, and decoder.
pub const NxCharClass = enum(u16) {
    han = 1,
    latin = 2,
    digit = 3,
    space = 4,
    punct = 5,
    symbol = 6,
    emoji = 7,
    other = 255,
};

// One scanned Unicode codepoint. Byte offsets slice source text; char_index addresses lattice positions.
pub const NxChar = extern struct {
    codepoint: u32,
    start_byte: u32,
    end_byte: u32,
    char_index: u32,
    char_class: NxCharClass,
    flags: u16 = 0,
};

// Source of a candidate edge or final token, used for explainable output.
pub const NxSource = enum(u16) {
    base_dict = 1,
    user_dict = 2,
    domain_dict = 3,
    rule = 4,
    unknown = 5,
    plugin = 6,
};

// Candidate edge in the lattice. Decoder depends only on this shape, not on its producer.
pub const NxEdge = extern struct {
    start_char: u32,
    end_char: u32,
    start_byte: u32,
    end_byte: u32,
    word_id: u32,
    score: f32,
    pos_id: u16,
    source: NxSource,
    flags: u16 = 0,
};
