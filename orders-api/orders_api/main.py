import os
import time
from typing import List

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request, Response, status
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from orders_api import metrics
from orders_api.models import Order, OrderIn
from orders_api.store import OrderStore

# Injected at image build time (see Dockerfile / Jenkinsfile) so the running
# version is visible in /health. The smoke test relies on this.
APP_VERSION = os.getenv("APP_VERSION", "dev")

router = APIRouter()


def get_store(request: Request) -> OrderStore:
    return request.app.state.store


def _not_found(order_id: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_404_NOT_FOUND, detail=f"order {order_id} not found"
    )


@router.get("/health")
def health() -> dict:
    return {"status": "ok", "version": APP_VERSION}


@router.get("/metrics", include_in_schema=False)
def prometheus_metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@router.post("/orders", response_model=Order, status_code=status.HTTP_201_CREATED)
def create_order(payload: OrderIn, store: OrderStore = Depends(get_store)) -> Order:
    order = store.create(payload)
    metrics.ORDERS_CREATED.inc()
    metrics.ORDERS_STORED.set(len(store))
    return order


@router.get("/orders", response_model=List[Order])
def list_orders(store: OrderStore = Depends(get_store)) -> List[Order]:
    return store.list()


@router.get("/orders/{order_id}", response_model=Order)
def get_order(order_id: str, store: OrderStore = Depends(get_store)) -> Order:
    order = store.get(order_id)
    if order is None:
        raise _not_found(order_id)
    return order


@router.put("/orders/{order_id}", response_model=Order)
def replace_order(order_id: str, payload: OrderIn, store: OrderStore = Depends(get_store)) -> Order:
    order = store.replace(order_id, payload)
    if order is None:
        raise _not_found(order_id)
    return order


@router.delete("/orders/{order_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_order(order_id: str, store: OrderStore = Depends(get_store)) -> Response:
    if not store.delete(order_id):
        raise _not_found(order_id)
    metrics.ORDERS_STORED.set(len(store))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def create_app() -> FastAPI:
    app = FastAPI(title="orders-api", version=APP_VERSION)
    app.state.store = OrderStore()

    @app.middleware("http")
    async def record_metrics(request: Request, call_next):
        start = time.perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        finally:
            # Label by route template ("/orders/{order_id}"), not the raw path,
            # so every order ID does not become its own time series.
            route = request.scope.get("route")
            route_path = getattr(route, "path", "unmatched")
            metrics.HTTP_REQUESTS.labels(request.method, route_path, str(status_code)).inc()
            metrics.HTTP_LATENCY.labels(request.method, route_path).observe(
                time.perf_counter() - start
            )

    app.include_router(router)
    return app


app = create_app()
