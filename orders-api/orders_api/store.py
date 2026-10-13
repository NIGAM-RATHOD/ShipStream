"""In-memory order storage.

Each process (and therefore each Kubernetes pod) has its own copy of the data.
That is deliberate: the service exists to exercise the pipeline, not to be a
real system of record.
"""
import threading
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Optional

from orders_api.models import Order, OrderIn


class OrderStore:
    def __init__(self) -> None:
        self._orders: Dict[str, Order] = {}
        self._lock = threading.Lock()

    def __len__(self) -> int:
        return len(self._orders)

    def create(self, data: OrderIn) -> Order:
        now = datetime.now(timezone.utc)
        order = Order(id=str(uuid.uuid4()), created_at=now, updated_at=now, **data.model_dump())
        with self._lock:
            self._orders[order.id] = order
        return order

    def list(self) -> List[Order]:
        with self._lock:
            return sorted(self._orders.values(), key=lambda o: o.created_at)

    def get(self, order_id: str) -> Optional[Order]:
        return self._orders.get(order_id)

    def replace(self, order_id: str, data: OrderIn) -> Optional[Order]:
        with self._lock:
            existing = self._orders.get(order_id)
            if existing is None:
                return None
            updated = Order(
                id=order_id,
                created_at=existing.created_at,
                updated_at=datetime.now(timezone.utc),
                **data.model_dump(),
            )
            self._orders[order_id] = updated
            return updated

    def delete(self, order_id: str) -> bool:
        with self._lock:
            return self._orders.pop(order_id, None) is not None
