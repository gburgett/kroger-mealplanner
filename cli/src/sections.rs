//! Which aisle a line belongs in.
//!
//! A heuristic, and it is allowed to be one: the point of the grouping is that
//! the housewife walks the store once, not that the classification is a truth.
//! Anything unrecognised goes to "Other", which is the honest answer, and the
//! line is still on the list — an ingredient we do not recognise must never be
//! dropped.
//!
//! The order below is the order the rules are tried in, and it matters. "corn
//! tortillas" holds "corn", so the pantry rule has to be asked before the
//! produce rule or a packet of tortillas ends up next to the sweetcorn.

pub const PRODUCE: &str = "Produce";
pub const MEAT: &str = "Meat & Seafood";
pub const DAIRY: &str = "Dairy";
pub const OTHER: &str = "Other";

/// The sections, in the order they are printed. A section with no lines in it
/// is not printed at all.
pub const ORDER: &[&str] = &[PRODUCE, MEAT, DAIRY, OTHER];

const RULES: &[(&str, &[&str])] = &[
    (
        MEAT,
        &[
            "chicken", "beef", "pork", "lamb", "turkey", "bacon", "sausage", "ham", "steak",
            "mince", "brisket", "thigh", "thighs", "breast", "breasts", "drumstick", "drumsticks",
            "fish", "salmon", "tuna", "cod", "haddock", "shrimp", "prawn", "prawns", "scallop",
            "scallops", "crab", "lobster",
        ],
    ),
    (
        DAIRY,
        &[
            "milk", "cream", "butter", "cheese", "cheddar", "mozzarella", "parmesan", "feta",
            "ricotta", "yoghurt", "yogurt", "egg", "eggs", "buttermilk",
        ],
    ),
    // Asked before produce on purpose. See the note above.
    (
        OTHER,
        &[
            "tortilla", "tortillas", "flour", "sugar", "salt", "rice", "pasta", "noodle",
            "noodles", "bread", "oil", "vinegar", "soup", "stock", "broth", "seasoning", "spice",
            "spices", "sauce", "beans" /* tinned, unless "green beans" caught below */,
        ],
    ),
    (
        PRODUCE,
        &[
            "onion", "onions", "garlic", "clove", "cloves", "tomato", "tomatoes", "potato",
            "potatoes", "carrot", "carrots", "celery", "lettuce", "spinach", "kale", "broccoli",
            "cauliflower", "cabbage", "pea", "peas", "bean", "beans", "mushroom", "mushrooms",
            "cucumber", "zucchini", "courgette", "squash", "apple", "apples", "banana", "bananas",
            "lemon", "lemons", "lime", "limes", "orange", "oranges", "avocado", "parsley",
            "cilantro", "coriander", "basil", "thyme", "rosemary", "ginger", "leek", "leeks",
        ],
    ),
];

/// Rules that run before everything else, because two keywords disagree and
/// the more specific phrase is right.
const PHRASES: &[(&str, &str)] = &[
    ("green bean", PRODUCE),
    ("runner bean", PRODUCE),
    ("broad bean", PRODUCE),
    ("baked bean", OTHER),
    ("sour cream", DAIRY),
    ("coconut milk", OTHER),
];

pub fn section_for(item: &str) -> &'static str {
    let lowered = item.to_ascii_lowercase();

    for (phrase, section) in PHRASES {
        if lowered.contains(phrase) {
            return section;
        }
    }

    let words: Vec<String> = lowered
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(|word| word.to_string())
        .collect();

    for (section, keywords) in RULES {
        if words.iter().any(|word| keywords.contains(&word.as_str())) {
            return section;
        }
    }

    OTHER
}
