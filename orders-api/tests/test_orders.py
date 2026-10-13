import pytest
from fastapi.testclient import TestClient

from orders_api.main import create_app
from orders_api.models import OrderIn
from orders_api.store import OrderStore

ORDER = {"customer": "acme", "item": "widget", "quantity": 3, "unit_price": 9.5}


@pytest.fixture
def client():
    # A fresh app per test means a fresh in-memory store per test.
    return TestClient(create_app())


@pytest.fixture
def created(client):
    resp = client.post("/orders", json=ORDER)
    assert resp.status_code == 201
    return resp.json()


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
    assert "version" in resp.json()


def test_metrics_exposes_custom_series(client, created):
    client.get(f"/orders/{created['id']}")
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/plain")
    body = resp.text
    assert "orders_api_orders_created_total" in body
    assert "orders_api_http_request_duration_seconds" in body
    # Routes are labelled by template, not by concrete order ID.
    assert 'route="/orders/{order_id}"' in body
    assert created["id"] not in body


def test_create_order(created):
    assert created["id"]
    assert created["status"] == "pending"
    assert created["quantity"] == 3
    assert created["created_at"] == created["updated_at"]


def test_list_orders(client, created):
    client.post("/orders", json={**ORDER, "item": "gadget"})
    resp = client.get("/orders")
    assert resp.status_code == 200
    assert [o["item"] for o in resp.json()] == ["widget", "gadget"]


def test_list_orders_empty(client):
    assert client.get("/orders").json() == []


def test_get_order(client, created):
    resp = client.get(f"/orders/{created['id']}")
    assert resp.status_code == 200
    assert resp.json() == created


def test_replace_order(client, created):
    resp = client.put(f"/orders/{created['id']}", json={**ORDER, "status": "shipped"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "shipped"
    assert body["created_at"] == created["created_at"]
    assert body["updated_at"] >= created["updated_at"]


def test_delete_order(client, created):
    assert client.delete(f"/orders/{created['id']}").status_code == 204
    assert client.get(f"/orders/{created['id']}").status_code == 404
    assert client.delete(f"/orders/{created['id']}").status_code == 404


@pytest.mark.parametrize("method", ["get", "delete"])
def test_unknown_order_returns_404(client, method):
    resp = getattr(client, method)("/orders/does-not-exist")
    assert resp.status_code == 404


def test_replace_unknown_order_returns_404(client):
    assert client.put("/orders/does-not-exist", json=ORDER).status_code == 404


@pytest.mark.parametrize(
    "override",
    [
        {"quantity": 0},
        {"quantity": 5000},
        {"unit_price": -1},
        {"customer": ""},
        {"status": "lost"},
    ],
)
def test_invalid_payload_returns_422(client, override):
    assert client.post("/orders", json={**ORDER, **override}).status_code == 422


def test_store_is_isolated_per_instance():
    a, b = OrderStore(), OrderStore()
    a.create(OrderIn(**ORDER))
    assert len(a) == 1
    assert len(b) == 0
