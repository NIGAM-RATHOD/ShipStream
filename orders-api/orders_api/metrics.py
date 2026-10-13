"""Prometheus metrics.

Metrics live at module level because prometheus-client registers them in a
process-wide registry; creating them inside create_app() would raise
"Duplicated timeseries" the second time an app is built (e.g. in tests).
"""
from prometheus_client import Counter, Gauge, Histogram

HTTP_REQUESTS = Counter(
    "orders_api_http_requests_total",
    "HTTP requests handled, by method, route template and status code.",
    ["method", "route", "status"],
)

HTTP_LATENCY = Histogram(
    "orders_api_http_request_duration_seconds",
    "HTTP request latency in seconds, by method and route template.",
    ["method", "route"],
)

ORDERS_CREATED = Counter(
    "orders_api_orders_created_total",
    "Orders created since the process started.",
)

ORDERS_STORED = Gauge(
    "orders_api_orders_stored",
    "Orders currently held in this pod's in-memory store.",
)
