SELECT 
	ca1.YearIs,
	ca1.MonthIs,
	ca1.WeekIs,
	COUNT(1) ExpeditedCount

FROM AuditLog al
CROSS APPLY (
	SELECT
		DATEPART(WEEK, al.CreateDate) WeekIs,
		DATEPART(MONTH, al.CreateDate) MonthIs,
		DATEPART(YEAR, al.CreateDate) YearIs
) ca1
WHERE 
	al.MessageType = 10151
	AND al.NewValue = '14'
GROUP BY
	ca1.YearIs,
	ca1.MonthIs,
	ca1.WeekIs
;