from datetime import datetime
from enum import Enum

from pydantic import BaseModel, Field


class OrderStatus(str, Enum):
    PENDING = "pending"
    SHIPPED = "shipped"
    DELIVERED = "delivered"
    CANCELLED = "cancelled"


class OrderIn(BaseModel):
    """Fields a client sends when creating or replacing an order."""

    customer: str = Field(min_length=1, max_length=100)
    item: str = Field(min_length=1, max_length=100)
    quantity: int = Field(gt=0, le=1000)
    unit_price: float = Field(ge=0)
    status: OrderStatus = OrderStatus.PENDING


class Order(OrderIn):
    id: str
    created_at: datetime
    updated_at: datetime
