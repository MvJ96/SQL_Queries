WITH jobTrn AS (
	SELECT 
		jt.trans_num TRNNum,
		jt.trans_date TRNDate,
		ca1.TRNYear,
		ca1.TRNWeek,
		jt.emp_num EmpNum,
		jt.qty_complete QtyComp,
		jt.qty_scrapped QtyScrp,
		jt.wc WC,
		ca1.WCType

	FROM jobtran_mst jt
	JOIN wc_mst wc			ON wc.wc = jt.wc
	JOIN dept_mst dep		ON dep.dept = wc.dept
	CROSS APPLY (
		SELECT
			YEAR(jt.trans_date) TRNYear,
			DATEPART(WEEK, jt.trans_date) TRNWeek,
			CASE 
				WHEN dep.description IN ('Hammers', 'Forge Presses  Automation') THEN 'H'
				WHEN dep.description = 'Upsetters' THEN 'U'
			END WCType
	) ca1

	WHERE 
		jt.trans_date >= '2026-01-01'
		AND jt.trans_type IN ('R', 'M')
		AND ca1.WCType IS NOT NULL
)

SELECT 
	jt.TRNYear,
	jt.TRNWeek,
	jt.WCType,
	SUM(jt.QtyComp) QtyComp,
	SUM(jt.QtyScrp) QtyScrap,
	SUM(jt.QtyComp + jt.QtyScrp) TotalQty

FROM jobTrn jt
GROUP BY
	jt.TRNYear,
	jt.TRNWeek,
	jt.WCType
ORDER BY
	jt.TRNYear,
	jt.TRNWeek,
	jt.WCType