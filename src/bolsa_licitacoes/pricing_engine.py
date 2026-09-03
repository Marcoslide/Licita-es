from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_CEILING, ROUND_HALF_UP
from typing import Any, Iterable, Mapping


CENT = Decimal("0.01")
RATE = Decimal("0.0001")


def decimal_value(value: Any) -> Decimal:
    """Convert external values without passing through binary floating point."""
    if value in (None, ""):
        return Decimal("0")
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def money(value: Any, *, ceiling: bool = False) -> Decimal:
    rounding = ROUND_CEILING if ceiling else ROUND_HALF_UP
    return decimal_value(value).quantize(CENT, rounding=rounding)


def rate(value: Any) -> Decimal:
    """A rate is expressed as a decimal fraction (10% == Decimal('0.10'))."""
    return decimal_value(value).quantize(RATE, rounding=ROUND_HALF_UP)


@dataclass(frozen=True)
class CostComponent:
    name: str
    category: str
    calculation_type: str = "AMOUNT"
    amount: Decimal = Decimal("0")
    unit_cost: Decimal = Decimal("0")
    quantity: Decimal = Decimal("0")
    revenue_rate: Decimal = Decimal("0")
    locked: bool = False
    minimum: Decimal = Decimal("0")

    @classmethod
    def from_mapping(cls, row: Mapping[str, Any]) -> "CostComponent":
        return cls(
            name=str(row.get("name") or "Custo"),
            category=str(row.get("category") or "OTHER").upper(),
            calculation_type=str(row.get("calculation_type") or "AMOUNT").upper(),
            amount=money(row.get("amount")),
            unit_cost=money(row.get("unit_cost")),
            quantity=decimal_value(row.get("quantity")),
            revenue_rate=rate(row.get("revenue_rate")),
            locked=bool(row.get("locked")),
            minimum=money(row.get("minimum")),
        )

    def fixed_total(self) -> Decimal:
        if self.calculation_type == "PER_UNIT":
            return money(self.unit_cost * self.quantity)
        if self.calculation_type == "PERCENT_REVENUE":
            return Decimal("0.00")
        return money(self.amount)


def _components(rows: Iterable[CostComponent | Mapping[str, Any]]) -> list[CostComponent]:
    return [row if isinstance(row, CostComponent) else CostComponent.from_mapping(row) for row in rows]


def calculate_pricing(
    components: Iterable[CostComponent | Mapping[str, Any]],
    *,
    sale_price: Any = 0,
    desired_margin: Any = 0,
    minimum_margin: Any = 0,
    explicit_operational_floor: Any = 0,
    price_to_win: Any | None = None,
) -> dict[str, Any]:
    """Calculate private-company economics using Decimal end-to-end.

    Percentage components are solved algebraically against revenue, so taxes and
    commissions are not approximated on top of a previously rounded price.
    """
    rows = _components(components)
    fixed = money(sum((row.fixed_total() for row in rows), Decimal("0")))
    variable_rate = rate(sum((row.revenue_rate for row in rows if row.calculation_type == "PERCENT_REVENUE"), Decimal("0")))
    desired = rate(desired_margin)
    minimum = rate(minimum_margin)
    if variable_rate >= 1:
        raise ValueError("Percentage costs must be below 100% of revenue")
    if variable_rate + desired >= 1 or variable_rate + minimum >= 1:
        raise ValueError("Cost rate plus margin must be below 100% of revenue")

    break_even = money(fixed / (Decimal("1") - variable_rate), ceiling=True)
    desired_price = money(fixed / (Decimal("1") - variable_rate - desired), ceiling=True)
    minimum_price = money(fixed / (Decimal("1") - variable_rate - minimum), ceiling=True)
    explicit_floor = money(explicit_operational_floor)
    operational_floor = max(minimum_price, explicit_floor)
    proposed = money(sale_price)
    variable_cost = money(proposed * variable_rate)
    total_cost = money(fixed + variable_cost)
    profit = money(proposed - total_cost)
    actual_margin = rate(profit / proposed) if proposed else Decimal("0")

    if not proposed:
        zone = "NOT_SIMULATED"
    elif proposed < break_even:
        zone = "LOSS"
    elif proposed < operational_floor:
        zone = "BELOW_OPERATIONAL_FLOOR"
    elif proposed < desired_price:
        zone = "VIABLE_BELOW_TARGET"
    else:
        zone = "TARGET_OR_ABOVE"

    by_category: dict[str, Decimal] = {}
    component_totals: list[dict[str, Any]] = []
    for row in rows:
        total = money(proposed * row.revenue_rate) if row.calculation_type == "PERCENT_REVENUE" else row.fixed_total()
        by_category[row.category] = money(by_category.get(row.category, Decimal("0")) + total)
        component_totals.append({"name": row.name, "category": row.category, "total": total})

    ptw = None if price_to_win in (None, "") else money(price_to_win)
    return {
        "fixed_cost": fixed,
        "variable_rate": variable_rate,
        "variable_cost": variable_cost,
        "total_cost": total_cost,
        "break_even": break_even,
        "minimum_margin_price": minimum_price,
        "desired_margin_price": desired_price,
        "operational_floor": operational_floor,
        "sale_price": proposed,
        "profit": profit,
        "actual_margin": actual_margin,
        "zone": zone,
        "price_to_win": ptw,
        "price_to_win_feasible": None if ptw is None else ptw >= operational_floor,
        "category_totals": by_category,
        "component_totals": component_totals,
    }


@dataclass(frozen=True)
class CompositionLine:
    name: str
    mode: str
    original_amount: Decimal
    minimum_amount: Decimal = Decimal("0")
    revenue_rate: Decimal = Decimal("0")

    @classmethod
    def from_mapping(cls, row: Mapping[str, Any]) -> "CompositionLine":
        return cls(
            name=str(row.get("name") or "Linha"),
            mode=str(row.get("mode") or "ADJUSTABLE").upper(),
            original_amount=money(row.get("original_amount")),
            minimum_amount=money(row.get("minimum_amount")),
            revenue_rate=rate(row.get("revenue_rate")),
        )


def redistribute_composition(
    lines: Iterable[CompositionLine | Mapping[str, Any]], target_total: Any
) -> dict[str, Any]:
    """Redistribute a final award total while preserving locks and exact cents."""
    rows = [row if isinstance(row, CompositionLine) else CompositionLine.from_mapping(row) for row in lines]
    target = money(target_total)
    fixed_modes = {"LOCKED", "FIXED"}
    flexible_modes = {"PROPORTIONAL", "ADJUSTABLE", "MARGIN", "RESIDUAL"}
    fixed_total = money(sum((row.original_amount for row in rows if row.mode in fixed_modes), Decimal("0")))
    percentage_values = {
        index: money(target * row.revenue_rate)
        for index, row in enumerate(rows) if row.mode == "PERCENTAGE"
    }
    percentage_total = money(sum(percentage_values.values(), Decimal("0")))
    flexible = [(index, row) for index, row in enumerate(rows) if row.mode in flexible_modes]
    minimum_total = money(sum((row.minimum_amount for _, row in flexible), Decimal("0")))
    committed = money(fixed_total + percentage_total + minimum_total)
    if target < committed:
        return {
            "feasible": False,
            "target_total": target,
            "minimum_total": committed,
            "shortfall": money(committed - target),
            "lines": [],
            "reason": "Locked, fixed, percentage and minimum costs exceed the target",
        }

    available = money(target - committed)
    weights = [max(row.original_amount - row.minimum_amount, CENT) for _, row in flexible]
    weight_total = sum(weights, Decimal("0"))
    allocated: dict[int, Decimal] = {}
    for position, ((index, row), weight) in enumerate(zip(flexible, weights)):
        share = available if position == len(flexible) - 1 else money(available * weight / weight_total)
        allocated[index] = money(row.minimum_amount + share)
        available = money(available - share)
        weight_total -= weight

    output: list[dict[str, Any]] = []
    for index, row in enumerate(rows):
        if row.mode in fixed_modes:
            amount = row.original_amount
        elif row.mode == "PERCENTAGE":
            amount = percentage_values[index]
        else:
            amount = allocated.get(index, row.minimum_amount)
        output.append({"name": row.name, "mode": row.mode, "amount": money(amount)})

    calculated_total = money(sum((row["amount"] for row in output), Decimal("0")))
    residual = money(target - calculated_total)
    if residual:
        residual_index = next(
            (index for index, row in enumerate(rows) if row.mode in {"RESIDUAL", "MARGIN", "ADJUSTABLE", "PROPORTIONAL"}),
            None,
        )
        if residual_index is None:
            return {
                "feasible": False,
                "target_total": target,
                "minimum_total": calculated_total,
                "shortfall": abs(residual),
                "lines": output,
                "reason": "No adjustable line can absorb the rounding residual",
            }
        output[residual_index]["amount"] = money(output[residual_index]["amount"] + residual)
    return {
        "feasible": True,
        "target_total": target,
        "minimum_total": committed,
        "shortfall": Decimal("0.00"),
        "lines": output,
        "calculated_total": money(sum((row["amount"] for row in output), Decimal("0"))),
        "reason": None,
    }
