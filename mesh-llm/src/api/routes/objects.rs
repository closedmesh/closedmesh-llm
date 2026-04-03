use super::super::{
    http::{respond_error, respond_json},
    MeshApi,
};
use crate::plugin;
use crate::plugin::blobstore::{
    abort_request, complete_request, put_request_object, FinishRequestRequest,
    PutRequestObjectRequest,
};
use tokio::net::TcpStream;

pub(super) async fn handle(
    stream: &mut TcpStream,
    state: &MeshApi,
    method: &str,
    path: &str,
    body: &str,
) -> anyhow::Result<()> {
    match (method, path) {
        ("POST", "/api/objects") => handle_put(stream, state, body).await,
        ("POST", "/api/objects/complete") => handle_finish(stream, state, body, true).await,
        ("POST", "/api/objects/abort") => handle_finish(stream, state, body, false).await,
        _ => Ok(()),
    }
}

async fn handle_put(stream: &mut TcpStream, state: &MeshApi, body: &str) -> anyhow::Result<()> {
    let plugin_manager = state.inner.lock().await.plugin_manager.clone();
    if !plugin_manager.is_available(plugin::BLOBSTORE_PLUGIN_ID) {
        respond_error(stream, 404, "Blobstore is disabled on this node").await?;
        return Ok(());
    }

    let request: PutRequestObjectRequest = match serde_json::from_str(body) {
        Ok(request) => request,
        Err(err) => {
            respond_error(stream, 400, &format!("Invalid JSON body: {err}")).await?;
            return Ok(());
        }
    };

    match put_request_object(&plugin_manager, request).await {
        Ok(response) => respond_json(stream, 201, &response).await?,
        Err(err) => respond_error(stream, 502, &err.to_string()).await?,
    }
    Ok(())
}

async fn handle_finish(
    stream: &mut TcpStream,
    state: &MeshApi,
    body: &str,
    complete: bool,
) -> anyhow::Result<()> {
    let plugin_manager = state.inner.lock().await.plugin_manager.clone();
    if !plugin_manager.is_available(plugin::BLOBSTORE_PLUGIN_ID) {
        respond_error(stream, 404, "Blobstore is disabled on this node").await?;
        return Ok(());
    }

    let request: FinishRequestRequest = match serde_json::from_str(body) {
        Ok(request) => request,
        Err(err) => {
            respond_error(stream, 400, &format!("Invalid JSON body: {err}")).await?;
            return Ok(());
        }
    };

    let result = if complete {
        complete_request(&plugin_manager, request).await
    } else {
        abort_request(&plugin_manager, request).await
    };
    match result {
        Ok(response) => respond_json(stream, 200, &response).await?,
        Err(err) => respond_error(stream, 502, &err.to_string()).await?,
    }
    Ok(())
}
