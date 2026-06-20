CREATE PROCEDURE ue_SLA_WeeklyWipAndCompValueSp(
	@WipTotal NVARCHAR(20) OUTPUT,
	@WipCompl NVARCHAR(20) OUTPUT,
	@WipRemng NVARCHAR(20) OUTPUT,
	@RawStock NVARCHAR(20) OUTPUT,
	@CmpStock NVARCHAR(20) OUTPUT,
	@FngStock NVARCHAR(20) OUTPUT
)
AS
SELECT 
	@WipTotal = FORMAT(ROUND(SUM(j.wip_total), 2), 'N2'),
	@WipCompl = FORMAT(ROUND(SUM(j.wip_complete), 2), 'N2'),
	@WipRemng = FORMAT(ROUND(SUM((j.wip_total - j.wip_complete)), 2), 'N2')

FROM job_mst j
WHERE
	j.type = 'J'
	AND j.stat IN ('R', 'S')
;

WITH CompCost AS (
	SELECT 
		ca1.CompType,
		FORMAT(ROUND(SUM((il.qty_on_hand * itm.cur_u_cost)), 0), 'N0') CurCost

	FROM itemloc_mst il
	JOIN item_mst itm		ON itm.item = il.item
	CROSS APPLY (
		SELECT
			CASE 
				WHEN itm.product_code BETWEEN 100 AND 199 THEN 'RAW MATERIALS'
				WHEN (itm.product_code BETWEEN 200 AND 500) OR itm.product_code = 601 THEN 'COMPONENTS'
				WHEN itm.product_code BETWEEN 900 AND 919 THEN 'FINISHED GOODS'
			END CompType
	) ca1
	WHERE il.whse = 'MAIN' AND itm.matl_type = 'M' AND CompType IS NOT NULL
	GROUP BY ca1.CompType
)

SELECT 
	@RawStock = (SELECT cc.CurCost FROM CompCost cc WHERE cc.CompType = 'RAW MATERIALS'),
	@CmpStock = (SELECT cc.CurCost FROM CompCost cc WHERE cc.CompType = 'COMPONENTS'),
	@FngStock = (SELECT cc.CurCost FROM CompCost cc WHERE cc.CompType = 'FINISHED GOODS')
;