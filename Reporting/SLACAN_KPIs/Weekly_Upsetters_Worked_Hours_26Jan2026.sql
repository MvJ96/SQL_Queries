SELECT 
	ca1.TRNYear,
	ca1.TRNWeek,
	ROUND(SUM(jt.a_hrs), 0) TotalHrs

FROM jobtran_mst jt
JOIN (
	SELECT 
		wc.wc,
		wc.description

	FROM wc_mst wc
	JOIN dept_mst dep ON dep.dept = wc.dept
	WHERE 
		wc.outside = 0
		AND dep.description = 'Upsetters'
) AS wc
	ON wc.wc = jt.wc

CROSS APPLY (
	SELECT 
		DATEPART(WEEK, jt.trans_date) TRNWeek,
		DATEPART(YEAR, jt.trans_date) TRNYear
) ca1

WHERE 
	ca1.TRNYear > 2025
	AND jt.trans_type IN ('S', 'R')

GROUP BY
	ca1.TRNYear,
	ca1.TRNWeek

ORDER BY
	ca1.TRNYear,
	ca1.TRNWeek