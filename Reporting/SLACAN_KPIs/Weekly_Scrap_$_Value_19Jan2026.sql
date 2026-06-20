IF OBJECT_ID('tempdb..#JobTransLines') IS NOT NULL DROP TABLE #JobTransLines;

CREATE TABLE #JobTransLines(
	TRNNum				DECIMAL(10, 0),
	TRNDate				DATE,
	Job					NVARCHAR(10),
	Suffix				INT,
	OperNum				INT,
	TRNType				NVARCHAR(1),
	QtyComp				DECIMAL(10, 2),
	QtyScrp				DECIMAL(10, 2),
	QtyMove				DECIMAL(10, 2),
	QtyAct				DECIMAL(10, 2),
	EmpNum				NVARCHAR(10),
	Scrp$Val			NVARCHAR(40),
	WC					NVARCHAR(6),
	WCDescription		NVARCHAR(40),
	QtyRecieved			DECIMAL(10, 2),
	ScrapPCT			DECIMAL(10, 2),
	EmpName				NVARCHAR(40),
	ReasonCode			NVARCHAR(3),
	ReasonDesc			NVARCHAR(40),
	FuncArea			NVARCHAR(30),
	Dept				NVARCHAR(6),
	DeptDesc			NVARCHAR(40),
	AHours				DECIMAL(10, 2),
	STime				DECIMAL(10, 2),
	ETime				DECIMAL(10, 2),
	Item				NVARCHAR(30),
	ItemDesc			NVARCHAR(40),
	TotalScrapValue		NVARCHAR(40),
	StartTime			DATE,
	EndTime				DATE,
	Shift				NVARCHAR(10),
	Rework				NVARCHAR(10),
	CreatedBy			NVARCHAR(128),
    ScrapReason         NVARCHAR(40)
);

INSERT INTO #JobTransLines
EXEC ue_SLA_ScrapDollarValueSp @SDateStr='2026-01-01', @EDateStr='2026-10-31'

SELECT 	
	ca1.TRNYear,
	ca1.TRNMonth,
	ca1.TRNWeek,
	SUM(ca1.TotalScrapValue) TotalScrapValue,	
	SUM(jt.QtyScrp) TotalScrapParts
	

FROM #JobTransLines jt
CROSS APPLY (
	SELECT
		DATEPART(WEEK, jt.TRNDate) TRNWeek,
		DATEPART(MONTH, jt.TRNDate) TRNMonth,
		DATEPART(YEAR, jt.TRNDate) TRNYear,
		TRY_CAST(REPLACE(SUBSTRING(jt.TotalScrapValue, 2, LEN(jt.TotalScrapValue) - 1), ',', '') AS DECIMAL(18, 5)) AS TotalScrapValue
) ca1
GROUP BY
	ca1.TRNYear,
	ca1.TRNMonth,
	ca1.TRNWeek
;
