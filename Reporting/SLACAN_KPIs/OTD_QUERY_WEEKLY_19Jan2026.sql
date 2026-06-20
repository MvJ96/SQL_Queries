--Slacan KPI 1. On Time Delivery

--DECLARE @Today AS DATE = GETDATE()
--DECLARE @NextDay AS DATE = DATEADD(DAY, 1, @Today)
--DECLARE @Weeks AS INT = 3
--DECLARE @CurWeek AS INT = DATEPART(WEEK, @Today)
--DECLARE @SDate AS DATE = DATEADD(DAY, -(DATEPART(WEEKDAY, @Today) + 6 + (7 * (@Weeks - 1))), @Today)
--DECLARE @EDate AS DATE = DATEADD(DAY, -(DATEPART(WEEKDAY, @Today) - (7 * (@Weeks + 1))), @Today);

WITH shipLines AS (
	SELECT 
		cs.co_num CoNum,
		cs.co_release CoRel,
		cs.co_line CoLine,
		ca1.ShipDate,
		ca1.ShipWeek,
		ca1.ShipMonth,
		ca1.ShipYear,
		ci.due_date DueDate,
		cs.price UnitPrice,
		cs.qty_shipped QtyShipped,
		ci.qty_ordered QtyOrdered,
		cs.qty_shipped * cs.price ShippedValue,
		ci.qty_ordered * ci.price OrderedValue,
		ca2.DaysDiff,
		CASE WHEN ca2.DaysDiff > -3 THEN 1 ELSE 0 END OnTime

	FROM co_ship_mst cs
	JOIN coitem_mst ci		ON ci.co_num = cs.co_num AND ci.co_release = cs.co_release AND ci.co_line = cs.co_line
	CROSS APPLY (
		SELECT
			CAST(cs.ship_date AS DATE) ShipDate,
			DATEPART(WEEK, cs.ship_date) ShipWeek,
			MONTH(cs.ship_date) ShipMonth,
			YEAR(cs.ship_date) ShipYear,
			CASE WHEN cs.qty_shipped >= (ci.qty_ordered * 0.9) THEN 1 ELSE 0 END FullyShipped,
			CASE WHEN cs.qty_shipped < (ci.qty_ordered * 0.9) THEN 1 ELSE 0 END PartiallyShipped
	) ca1

	CROSS APPLY (
		SELECT 
			DATEDIFF(DAY, ca1.ShipDate, ci.due_date) DaysDiff
	) ca2
	WHERE ca1.ShipDate BETWEEN '2025-01-01' AND GETDATE()
)

, aggrTab AS (
	SELECT 
		sl.ShipWeek,
		--sl.ShipMonth,
		--SUBSTRING('Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec ', (sl.ShipMonth * 4) - 3, 3) ShipMonthStr,
		sl.ShipYear,
		SUM(CASE WHEN sl.OnTime = 1 THEN 1 ELSE 0 END) OnTimeCount,
		SUM(CASE WHEN sl.OnTime = 0 THEN 1 ELSE 0 END) LateCount,
		COUNT(1) TotalCount,
		SUM(CASE WHEN sl.OnTime = 1 THEN sl.ShippedValue ELSE 0 END) OnTimeShippedValue,
		SUM(CASE WHEN sl.OnTime = 0 THEN sl.ShippedValue ELSE 0 END) LateShippedValue,
		SUM(sl.ShippedValue) TotalShippedValue

	FROM shipLines sl
	GROUP BY
		sl.ShipWeek,
		--sl.ShipMonth,
		sl.ShipYear
)

SELECT
	at.*,
	ROUND((at.OnTimeCount * 1.0/at.TotalCount), 2) OnTimeDelPrct,
	ROUND((at.LateCount * 1.0/at.TotalCount), 2) LateDelPrct,
	ROUND(at.OnTimeShippedValue/at.TotalShippedValue, 2) OnTimeShippedValuePrct,
	ROUND(at.LateShippedValue/at.TotalShippedValue, 2) LateShippedValuePrct

FROM aggrTab at
ORDER BY 
	at.ShipYear,
	--at.ShipMonth,
	at.ShipWeek
;
