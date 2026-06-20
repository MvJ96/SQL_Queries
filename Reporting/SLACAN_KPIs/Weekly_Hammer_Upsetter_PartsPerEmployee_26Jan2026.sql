WITH TRNData AS (
	SELECT 
		jt.trans_date TRNDate,
		jt.emp_num EmpNum,
		SUM((jt.qty_complete + jt.qty_scrapped)) QtyTotal

	FROM jobtran_mst jt
	JOIN wc_mst wc			ON wc.wc = jt.wc
	JOIN dept_mst dep		ON dep.dept = wc.dept
	WHERE
		jt.trans_type IN ('R', 'M')
		AND jt.trans_date >= '2026-01-01'
		AND dep.description IN ('Hammers','Upsetters', 'Forge Presses  Automation')	-- Added 'Forge Presses  Automation' - they are considered hammers -03Feb2026
	GROUP BY
		jt.trans_date,
		jt.emp_num
)

, aggData AS (
	SELECT 
		ca1.TRNYear,
		ca1.TRNWeek,
		COUNT(td.EmpNum) EmpCount,
		SUM(td.QtyTotal) QtyTotal

	FROM TRNData td
	CROSS APPLY (
		SELECT
			DATEPART(YEAR, td.TRNDate) TRNYear,
			DATEPART(WEEK, td.TRNDate) TRNWeek
	) ca1
	GROUP BY
		ca1.TRNYear,
		ca1.TRNWeek
)

SELECT 
	ad.TRNYear,
	ad.TRNWeek,
	ROUND(ad.QtyTotal/ad.EmpCount, 2) PartsPerEmp

FROM aggData ad
;