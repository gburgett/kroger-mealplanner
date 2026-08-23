//! Quantities, units and the arithmetic over them.
//!
//! Two rules from the domain, and both are conservative on purpose:
//!
//!   * Quantities combine only when their units convert. US customary volume
//!     and metric volume do not convert exactly, so they never combine — the
//!     item keeps separate lines rather than being silently guessed at.
//!   * Countable items round up. You cannot buy 1.5 onions.
//!
//! Everything is a rational number. A third of a cup is a real measurement and
//! no decimal type holds one; `0.333333 cup` is as wrong as
//! `0.30000000000000004 cup`.

use num_rational::Ratio;
use num_traits::{One, Signed, Zero};

pub type Number = Ratio<i128>;

/// What a unit measures. Units convert inside a family and never across one.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Family {
    Count,
    UsVolume,
    MetricVolume,
    UsWeight,
    MetricWeight,
}

/// A unit, its family, and how many base units it is worth.
///
/// The base of each family is its smallest unit, and every factor is a whole
/// number, so no conversion inside a family loses anything.
#[derive(Clone, Copy, Debug)]
pub struct Unit {
    pub canonical: &'static str,
    pub family: Family,
    /// How many of the family's base unit this one is worth.
    pub base: i128,
    /// Whether the ladder may promote a total up to this unit for display.
    pub display: bool,
}

const UNITS: &[(&[&str], Unit)] = &[
    // US volume, based on the teaspoon.
    (&["tsp", "teaspoon", "teaspoons"], Unit { canonical: "tsp", family: Family::UsVolume, base: 1, display: true }),
    (&["tbsp", "tablespoon", "tablespoons"], Unit { canonical: "tbsp", family: Family::UsVolume, base: 3, display: true }),
    (&["floz", "fl-oz"], Unit { canonical: "floz", family: Family::UsVolume, base: 6, display: false }),
    (&["cup", "cups"], Unit { canonical: "cup", family: Family::UsVolume, base: 48, display: true }),
    // A shopping list says "3 cup", never "1.5 pint". These convert on the way
    // in and are never promoted to on the way out.
    (&["pint", "pints", "pt"], Unit { canonical: "pint", family: Family::UsVolume, base: 96, display: false }),
    (&["quart", "quarts", "qt"], Unit { canonical: "quart", family: Family::UsVolume, base: 192, display: false }),
    (&["gallon", "gallons", "gal"], Unit { canonical: "gallon", family: Family::UsVolume, base: 768, display: false }),
    // Metric volume, based on the millilitre. Deliberately not convertible to
    // the above: 1 tsp is 4.92892159375 ml, and rounding a recipe is not our job.
    (&["ml", "milliliter", "milliliters", "millilitre", "millilitres"], Unit { canonical: "ml", family: Family::MetricVolume, base: 1, display: true }),
    (&["l", "liter", "liters", "litre", "litres"], Unit { canonical: "l", family: Family::MetricVolume, base: 1000, display: true }),
    // US weight, based on the ounce.
    (&["oz", "ounce", "ounces"], Unit { canonical: "oz", family: Family::UsWeight, base: 1, display: true }),
    (&["lb", "lbs", "pound", "pounds"], Unit { canonical: "lb", family: Family::UsWeight, base: 16, display: true }),
    // Metric weight, based on the gram.
    (&["g", "gram", "grams"], Unit { canonical: "g", family: Family::MetricWeight, base: 1, display: true }),
    (&["kg", "kilogram", "kilograms"], Unit { canonical: "kg", family: Family::MetricWeight, base: 1000, display: true }),
];

pub fn unit_named(word: &str) -> Option<Unit> {
    let lowered = word.to_ascii_lowercase();
    UNITS
        .iter()
        .find(|(names, _)| names.contains(&lowered.as_str()))
        .map(|(_, unit)| *unit)
}

/// A quantity in its family's base unit, or a bare count.
#[derive(Clone, Copy, Debug)]
pub struct Measure {
    pub amount: Number,
    pub family: Family,
}

impl Measure {
    pub fn of(amount: Number, unit: Option<Unit>) -> Self {
        match unit {
            None => Measure { amount, family: Family::Count },
            Some(unit) => Measure { amount: amount * Ratio::from_integer(unit.base), family: unit.family },
        }
    }

    pub fn add(self, other: Measure) -> Option<Measure> {
        if self.family != other.family {
            return None;
        }
        Some(Measure { amount: self.amount + other.amount, family: self.family })
    }

    pub fn scaled(self, factor: Number) -> Measure {
        Measure { amount: self.amount * factor, family: self.family }
    }

    /// How the line reads on a shopping list.
    ///
    /// A count rounds up, because you cannot buy 1.5 onions. A measure climbs
    /// to the largest unit that leaves it at one or more — 28 oz reads as
    /// "1.75 lb" — and stops at the cup, because a shopping list says "3 cup"
    /// and not "1.5 pint".
    pub fn render(self) -> String {
        if self.family == Family::Count {
            return format_number(round_up(self.amount));
        }
        let ladder: Vec<Unit> = UNITS
            .iter()
            .map(|(_, unit)| *unit)
            .filter(|unit| unit.family == self.family && unit.display)
            .collect();
        let mut chosen = ladder.first().copied().expect("every family has a base unit");
        for unit in &ladder {
            let value = self.amount / Ratio::from_integer(unit.base);
            if value.abs() >= Ratio::one() {
                chosen = *unit;
            }
        }
        let value = self.amount / Ratio::from_integer(chosen.base);
        format!("{} {}", format_number(value), chosen.canonical)
    }
}

fn round_up(value: Number) -> Number {
    Ratio::from_integer(value.ceil().to_integer())
}

/// Read "1.5", "12", "1 1/2" or "1/4".
///
/// Returns the number and how many words of the input it consumed, so the
/// caller knows where the unit or the item starts.
pub fn parse_quantity(words: &[&str]) -> Option<(Number, usize)> {
    let first = words.first()?;
    // "1 1/2" — a whole number and a fraction, in that order.
    if let (Some(whole), Some(second)) = (parse_integer(first), words.get(1)) {
        if let Some(fraction) = parse_fraction(second) {
            if fraction.is_positive() && fraction < Ratio::one() {
                return Some((Ratio::from_integer(whole) + fraction, 2));
            }
        }
    }
    parse_number(first).map(|number| (number, 1))
}

fn parse_integer(word: &str) -> Option<i128> {
    if word.is_empty() || !word.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    word.parse().ok()
}

fn parse_fraction(word: &str) -> Option<Number> {
    let (top, bottom) = word.split_once('/')?;
    let top = parse_integer(top)?;
    let bottom = parse_integer(bottom)?;
    if bottom == 0 {
        return None;
    }
    Some(Ratio::new(top, bottom))
}

/// "12", "1.5" or "1/4". Not "1 1/2" — that is two words.
pub fn parse_number(word: &str) -> Option<Number> {
    if let Some(fraction) = parse_fraction(word) {
        return Some(fraction);
    }
    if let Some(whole) = parse_integer(word) {
        return Some(Ratio::from_integer(whole));
    }
    let (whole, decimals) = word.split_once('.')?;
    if decimals.is_empty() || !decimals.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let whole = if whole.is_empty() { 0 } else { parse_integer(whole)? };
    let scale = 10i128.checked_pow(decimals.len() as u32)?;
    let fraction: i128 = decimals.parse().ok()?;
    Some(Ratio::from_integer(whole) + Ratio::new(fraction, scale))
}

/// Write a rational the way a cook would.
///
/// An exact decimal is printed as one — 1.75, 0.25, 3. Anything else keeps its
/// fraction, so a third of a cup reads "1/3" rather than "0.333333".
pub fn format_number(value: Number) -> String {
    let negative = value.is_negative();
    let value = value.abs();
    let mut denominator = *value.denom();
    let mut places = 0usize;
    while denominator % 2 == 0 {
        denominator /= 2;
        places += 1;
    }
    let mut fives = 0usize;
    while denominator % 5 == 0 {
        denominator /= 5;
        fives += 1;
    }
    let sign = if negative { "-" } else { "" };

    if denominator != 1 {
        // Not an exact decimal. "1 1/3" reads better than any rounding of it.
        let whole = value.to_integer();
        let rest = value - Ratio::from_integer(whole);
        if whole.is_zero() {
            return format!("{sign}{}/{}", rest.numer(), rest.denom());
        }
        if rest.is_zero() {
            return format!("{sign}{whole}");
        }
        return format!("{sign}{whole} {}/{}", rest.numer(), rest.denom());
    }

    let places = places.max(fives);
    if places == 0 {
        return format!("{sign}{}", value.to_integer());
    }
    let scale = 10i128.pow(places as u32);
    let scaled = (value * Ratio::from_integer(scale)).to_integer();
    let whole = scaled / scale;
    let fraction = (scaled % scale).abs();
    let mut text = format!("{fraction:0width$}", width = places);
    while text.ends_with('0') {
        text.pop();
    }
    if text.is_empty() {
        format!("{sign}{whole}")
    } else {
        format!("{sign}{whole}.{text}")
    }
}

/// For the --json output, which reports what the parser read.
pub fn to_display_number(value: Number) -> String {
    format_number(value)
}
