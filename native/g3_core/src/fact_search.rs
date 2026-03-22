use std::collections::{HashMap, HashSet};

use regex::Regex;
use serde::Serialize;

use crate::models::TrackerItem;

const DEFAULT_LIMIT: usize = 5;
const K1: f64 = 1.2;
const B: f64 = 0.75;

#[derive(Debug, Clone, Serialize)]
pub struct SearchResult {
    pub id: String,
    pub title: Option<String>,
    pub project_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub score: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub matches: Option<usize>,
    pub snippet: String,
}

pub fn bm25(query: &str, facts: &[TrackerItem], limit: usize) -> Vec<SearchResult> {
    let limit = if limit == 0 { DEFAULT_LIMIT } else { limit };
    let query_tokens = tokenize(query).into_iter().collect::<HashSet<_>>();
    if query_tokens.is_empty() {
        return Vec::new();
    }

    let documents = facts.iter().map(Document::new).collect::<Vec<_>>();
    let document_count = documents.len().max(1) as f64;
    let average_length = average_document_length(&documents);
    let frequencies = document_frequencies(&documents, &query_tokens);

    let mut scored = documents
        .into_iter()
        .filter_map(|document| {
            let score = bm25_score(
                &document,
                &query_tokens,
                &frequencies,
                document_count,
                average_length,
            );

            if score > 0.0 {
                Some(SearchResult {
                    id: document.fact.id.clone(),
                    title: document.fact.title.clone(),
                    project_title: document.fact.project_title.clone(),
                    score: Some((score * 10_000.0).round() / 10_000.0),
                    field: None,
                    matches: None,
                    snippet: best_snippet(document.fact, &query_tokens),
                })
            } else {
                None
            }
        })
        .collect::<Vec<_>>();

    scored.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.title.cmp(&right.title))
    });
    scored.truncate(limit);
    scored
}

pub fn grep(pattern: &str, facts: &[TrackerItem], limit: usize) -> Vec<SearchResult> {
    let limit = if limit == 0 { DEFAULT_LIMIT } else { limit };
    let regex = Regex::new(pattern)
        .or_else(|_| Regex::new(&regex::escape(pattern)))
        .ok();

    let Some(regex) = regex else {
        return Vec::new();
    };

    facts
        .iter()
        .filter_map(|fact| {
            for (field, value) in [
                ("title", fact.title.as_deref()),
                ("summary", fact.summary.as_deref()),
                ("details", fact.details.as_deref()),
                ("project_title", fact.project_title.as_deref()),
            ] {
                let Some(value) = value else {
                    continue;
                };
                let matches = regex.find_iter(value).count();
                if matches > 0 {
                    return Some(SearchResult {
                        id: fact.id.clone(),
                        title: fact.title.clone(),
                        project_title: fact.project_title.clone(),
                        score: None,
                        field: Some(field.to_string()),
                        matches: Some(matches),
                        snippet: snippet(value),
                    });
                }
            }
            None
        })
        .take(limit)
        .collect()
}

struct Document<'a> {
    fact: &'a TrackerItem,
    tokens: Vec<String>,
    frequencies: HashMap<String, usize>,
}

impl<'a> Document<'a> {
    fn new(fact: &'a TrackerItem) -> Self {
        let tokens = weighted_tokens(fact.title.as_deref(), 4)
            .into_iter()
            .chain(weighted_tokens(fact.summary.as_deref(), 2))
            .chain(weighted_tokens(fact.details.as_deref(), 3))
            .chain(weighted_tokens(fact.project_title.as_deref(), 2))
            .collect::<Vec<_>>();

        let mut frequencies = HashMap::new();
        for token in &tokens {
            *frequencies.entry(token.clone()).or_insert(0) += 1;
        }

        Self {
            fact,
            tokens,
            frequencies,
        }
    }
}

fn weighted_tokens(text: Option<&str>, weight: usize) -> Vec<String> {
    let Some(text) = text else {
        return Vec::new();
    };

    tokenize(text)
        .into_iter()
        .flat_map(|token| std::iter::repeat(token).take(weight))
        .collect()
}

fn tokenize(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|ch: char| !ch.is_ascii_alphanumeric())
        .filter(|token| !token.is_empty())
        .map(ToString::to_string)
        .collect()
}

fn average_document_length(documents: &[Document<'_>]) -> f64 {
    if documents.is_empty() {
        1.0
    } else {
        documents
            .iter()
            .map(|document| document.tokens.len() as f64)
            .sum::<f64>()
            / documents.len() as f64
    }
}

fn document_frequencies(
    documents: &[Document<'_>],
    query_tokens: &HashSet<String>,
) -> HashMap<String, usize> {
    query_tokens
        .iter()
        .map(|token| {
            let frequency = documents
                .iter()
                .filter(|document| document.frequencies.contains_key(token))
                .count();
            (token.clone(), frequency)
        })
        .collect()
}

fn bm25_score(
    document: &Document<'_>,
    query_tokens: &HashSet<String>,
    document_frequencies: &HashMap<String, usize>,
    document_count: f64,
    average_length: f64,
) -> f64 {
    query_tokens.iter().fold(0.0, |score, token| {
        let term_frequency = *document.frequencies.get(token).unwrap_or(&0) as f64;
        if term_frequency == 0.0 {
            return score;
        }

        let document_frequency = *document_frequencies.get(token).unwrap_or(&0) as f64;
        let idf =
            (1.0 + (document_count - document_frequency + 0.5) / (document_frequency + 0.5)).ln();
        let numerator = term_frequency * (K1 + 1.0);
        let denominator =
            term_frequency + K1 * (1.0 - B + B * document.tokens.len() as f64 / average_length);
        score + idf * numerator / denominator
    })
}

fn best_snippet(fact: &TrackerItem, query_tokens: &HashSet<String>) -> String {
    for value in [
        fact.details.as_deref(),
        fact.summary.as_deref(),
        fact.title.as_deref(),
        fact.project_title.as_deref(),
    ] {
        if let Some(value) = value {
            let lower = value.to_lowercase();
            if query_tokens.iter().any(|token| lower.contains(token)) {
                return snippet(value);
            }
        }
    }

    snippet(
        fact.details
            .as_deref()
            .or(fact.summary.as_deref())
            .or(fact.title.as_deref())
            .or(fact.project_title.as_deref())
            .unwrap_or_default(),
    )
}

fn snippet(text: &str) -> String {
    if text.chars().count() > 180 {
        format!("{}...", text.chars().take(177).collect::<String>())
    } else {
        text.to_string()
    }
}
