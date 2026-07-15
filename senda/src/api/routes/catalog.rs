use super::super::http::respond_json;
use crate::models::catalog::{self, CatalogModel};
use serde_json::{json, Value};
use url::form_urlencoded;

/// `GET /api/catalog` — the curated model catalog as JSON.
///
/// Returns the `listed` catalog entries (the same curated set the CLI and
/// website surface). Pass `?all=true` to include hidden/legacy entries too.
/// This is the runtime-side source of truth the website proxies so a model can
/// be added or retired in one place (the runtime `catalog.json`) instead of
/// hand-maintaining a second list on the site.
pub(super) async fn handle(stream: &mut tokio::net::TcpStream, path: &str) -> anyhow::Result<()> {
    let include_hidden = parse_include_hidden(path);
    let models: Vec<Value> = catalog::MODEL_CATALOG
        .iter()
        .filter(|model| include_hidden || model.listed)
        .map(catalog_entry_json)
        .collect();
    let payload = json!({
        "ok": true,
        "source": "catalog",
        "count": models.len(),
        "catalog": models,
    });
    respond_json(stream, 200, &payload).await
}

fn parse_include_hidden(path: &str) -> bool {
    let Some((_, raw_query)) = path.split_once('?') else {
        return false;
    };
    form_urlencoded::parse(raw_query.as_bytes())
        .any(|(key, value)| key == "all" && matches!(value.as_ref(), "true" | "1" | "yes"))
}

fn catalog_entry_json(model: &CatalogModel) -> Value {
    json!({
        "id": model.name,
        "size": model.size,
        "sizeGb": catalog::parse_size_gb(&model.size),
        "description": model.description,
        "draft": model.draft,
        "vision": model.mmproj.is_some(),
        "moe": model.moe.is_some(),
        "listed": model.listed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curated_entries_only_by_default() {
        let listed = catalog::listed_models();
        let all = catalog::MODEL_CATALOG.len();
        assert!(listed.len() < all, "some entries should be hidden");
        assert!(!parse_include_hidden("/api/catalog"));
        assert!(parse_include_hidden("/api/catalog?all=true"));
        assert!(!parse_include_hidden("/api/catalog?all=false"));
    }

    #[test]
    fn entry_json_derives_vision_and_size() {
        let vision = catalog::find_model("Gemma-3-12B-it-Q4_K_M").unwrap();
        let entry = catalog_entry_json(vision);
        assert_eq!(entry["vision"], json!(true));
        assert_eq!(entry["id"], json!("Gemma-3-12B-it-Q4_K_M"));
        assert!(entry["sizeGb"].as_f64().unwrap() > 0.0);
    }
}
