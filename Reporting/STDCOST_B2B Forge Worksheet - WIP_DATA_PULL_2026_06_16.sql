--This query was developed for Manufacturing Team to provide them past Standard Job Costing at each operation.
--It provides accurate costing for further data analysis and Scrap Reporting for Manufacturing Team.

DECLARE @Job AS NVARCHAR(10) = '    199334'; --'    196440';
DECLARE @GetCost AS TINYINT = 1;

-- ADDING JOBS DATA
BEGIN
	IF OBJECT_ID('tempdb..#Jobs') IS NOT NULL DROP TABLE #Jobs;
	CREATE TABLE #Jobs(
		Job				NVARCHAR(10) NOT NULL,
		Suffix			INT NOT NULL,
		Item			NVARCHAR(30) NOT NULL,
		ItemDescription	NVARCHAR(40),
		ClosedDate		DATE,
		JobDate			DATE,
		QtyComp			DECIMAL(18, 5),
		QtyScrp			DECIMAL(18, 5),
		TotalQty		DECIMAL(18, 5)

		PRIMARY KEY CLUSTERED (Job, Suffix)
	)

	INSERT INTO #Jobs(Job, Suffix, Item, ItemDescription, ClosedDate, JobDate, QtyComp, QtyScrp, TotalQty)
	SELECT 
		j.job Job,
		j.suffix Suffix,
		j.item Item,
		itm.description ItemDescription,
		j.lst_trx_date ClosedDate,
		j.job_date JobDate,
		j.qty_complete QtyComp,
		j.qty_scrapped QtyScrp,
		(j.qty_complete + j.qty_scrapped) TotalQty

	FROM job_mst j
	JOIN item_mst itm
		ON itm.item = j.item
	WHERE
		j.stat = 'C'
		AND j.type = 'J'
		AND j.lst_trx_date >= '2020-01-01' AND j.lst_trx_date < '2026-01-01'
		AND j.job_date >= '2016-01-01'
		AND (j.qty_complete + j.qty_scrapped) > 0
		--AND j.job = @Job
	;
END;

IF @GetCost = 0
	BEGIN
		SELECT 
			DATEPART(YEAR, j.JobDate) ClosedYear,
			DATEPART(MONTH, j.JobDate) ClosedMonth,
			j.ClosedDate,
			j.Job,
			j.Suffix,
			j.Item,
			j.ItemDescription,
			j.JobDate,
			j.QtyComp,
			j.QtyScrp

		FROM #Jobs j
		ORDER BY 1, 2, j.Job, j.Suffix;
		RETURN;
	END;

-- ADDING WC DATA
BEGIN 
	IF OBJECT_ID('tempdb..#ForgeWC') IS NOT NULL DROP TABLE #ForgeWC;
	CREATE TABLE #ForgeWC(
		WC	NVARCHAR(6) NOT NULL
		PRIMARY KEY(WC)
	)
	;

	INSERT INTO #ForgeWC(WC)
	VALUES	('3150'),('5000'),('2000'),('2712'),('0816'),('0022'),('0838'),('2594'),('0271'),('2651'),('0003')
	;
END;

-- ADDING JOBCOST DATA
BEGIN 

	IF OBJECT_ID('tempdb..#JobCostData') IS NOT NULL DROP TABLE #JobCostData;

	CREATE TABLE #JobCostData(
		Job			NVARCHAR(10) NOT NULL,
		Suffix		INT NOT NULL,
		OperNum		INT NOT NULL,
		WC			NVARCHAR(6),
		OpCompQty	DECIMAL(18, 5),
		OpScrpQty	DECIMAL(18, 5),
		OpCost		DECIMAL(18, 5)

		PRIMARY KEY CLUSTERED (Job, Suffix, OperNum)
	)
	;

	WITH JobRouteCostData AS (
		SELECT 
			j.Job,
			j.Suffix,
			jr.oper_num OperNum,
			jr.wc WC,
			wc.overhead Overhead,
			wc.outside Outside,
			j.TotalQty - SUM(jr.qty_scrapped) OVER(PARTITION BY jr.job, jr.suffix ORDER BY jr.oper_num) OpCompQty,
			jr.qty_scrapped OpScrpQty,

			jrt.run_ticks_lbr / jr.efficiency RunHrsLbr,
			jrt.run_ticks_mch / jr.efficiency RunHrsMch,
			jrt.setup_ticks / jr.efficiency SetupHrs,
			ISNULL(jrt.sched_hrs, 0) SchdHrs,

			GREATEST(jr.setup_rate, jr.run_rate_lbr) SetupRate,
			jr.run_rate_lbr RunRateLbr,
	
			jr.fixovhd_rate FOHRate,
			jr.varovhd_rate VOHRate,
			jr.vovhd_rate_mch VOHMchRate,
			jr.fovhd_rate_mch FOHMchRate

		FROM #Jobs j
		JOIN jobroute_mst jr
			ON jr.job = j.Job AND jr.suffix = j.Suffix
		JOIN jrt_sch_mst jrt
			ON jrt.job = jr.job AND jrt.suffix = jr.suffix AND jrt.oper_num = jr.oper_num
		JOIN wc_mst wc
			ON wc.wc = jr.wc
	)

	, JobRouteCost AS (
		SELECT 
			jrc.Job, jrc.Suffix, jrc.OperNum, jrc.WC, jrc.OpCompQty, jrc.OpScrpQty,

			CASE
				WHEN jrc.Outside = 0 AND jrc.SchdHrs = 0 THEN (jrc.RunRateLbr * jrc.RunHrsLbr * (jrc.OpCompQty + jrc.OpScrpQty)) + (jrc.SetupHrs * jrc.SetupRate)
				ELSE 0
			END LbrCost,

			CASE
				WHEN jrc.Outside = 0 AND jrc.SchdHrs = 0 AND jrc.Overhead LIKE '%L%' THEN (jrc.FOHRate * jrc.RunHrsLbr * (jrc.OpCompQty + jrc.OpScrpQty)) + (jrc.SetupHrs * jrc.FOHRate)
				ELSE 0
			END FOHCost,

			CASE
				WHEN jrc.Outside = 0 AND jrc.SchdHrs = 0 AND jrc.Overhead LIKE '%L%' THEN (jrc.VOHRate * jrc.RunHrsLbr * (jrc.OpCompQty + jrc.OpScrpQty)) + (jrc.SetupHrs * jrc.VOHRate)
				ELSE 0
			END VOHCost,

			CASE
				WHEN jrc.Outside = 0 AND jrc.SchdHrs = 0 AND jrc.Overhead LIKE '%C%' THEN (jrc.FOHMchRate * jrc.RunHrsLbr * (jrc.OpCompQty + jrc.OpScrpQty))
				ELSE 0
			END FOHMchCost,

			CASE
				WHEN jrc.Outside = 0 AND jrc.SchdHrs = 0 AND jrc.Overhead LIKE '%C%' THEN (jrc.VOHMchRate * jrc.RunHrsLbr * (jrc.OpCompQty + jrc.OpScrpQty))
				ELSE 0
			END VOHMchCost

		FROM JobRouteCostData jrc
		WHERE (jrc.OpCompQty + jrc.OpScrpQty) > 0
	)

	, JobMatlCost AS (
	SELECT 
		jrc.Job,
		jrc.Suffix,
		jrc.OperNum,
		SUM(ISNULL(NULLIF(itm.unit_cost, 0), ISNULL(jm.cost_conv, 0)) * (CASE WHEN jm.units = 'U' THEN jm.matl_qty_conv * (jrc.OpCompQty + jrc.OpScrpQty) ELSE 1 END)) MaterialCost

	FROM JobRouteCost jrc
	JOIN jobmatl_mst jm
		ON jm.job = jrc.Job AND jm.suffix = jrc.Suffix AND jm.oper_num = jrc.OperNum
	LEFT JOIN item_mst itm
		ON itm.item = jm.item
	GROUP BY
		jrc.Job, jrc.Suffix, jrc.OperNum
	)

	INSERT INTO #JobCostData(Job, Suffix, OperNum, WC, OpCompQty, OpScrpQty, OpCost)
	SELECT 
		jrc.Job,
		jrc.Suffix,
		jrc.OperNum,
		jrc.WC,
		jrc.OpCompQty,
		jrc.OpScrpQty,
		(jrc.LbrCost + jrc.FOHCost + jrc.FOHMchCost + jrc.VOHMchCost) + ISNULL(jm.MaterialCost, 0) + (((jrc.LbrCost + jrc.FOHCost + jrc.FOHMchCost + jrc.VOHMchCost) + ISNULL(jm.MaterialCost, 0)) * 0.5) OpCost	-- + jrc.VOHCost

	FROM JobRouteCost jrc
	LEFT JOIN JobMatlCost jm
		ON jm.Job = jrc.Job AND jm.Suffix = jrc.Suffix AND jm.OperNum = jrc.OperNum
	ORDER BY
		jrc.Job, jrc.Suffix, jrc.OperNum
	;
END;

IF OBJECT_ID('tempdb..#ForgeOpData') IS NOT NULL DROP TABLE #ForgeOpData;

WITH LastForgeOp AS (
	SELECT 
		jcd.Job, jcd.Suffix, MAX(jcd.OperNum) LastForgedOp

	FROM #JobCostData jcd
	JOIN #ForgeWC fwc
		ON fwc.WC = jcd.WC
	GROUP BY
		jcd.Job, jcd.Suffix
)

, WithUnitCost AS (
	SELECT 
		jcd.*,
		(jcd.OpCost / NULLIF((jcd.OpCompQty + jcd.OpScrpQty), 0)) UnitOpCost,
		CASE WHEN jcd.OperNum <= ISNULL(lfo.LastForgedOp, 0) THEN 0 ELSE 1 END AfterForge

	FROM #JobCostData jcd
	LEFT JOIN LastForgeOp lfo
		ON lfo.Job = jcd.Job AND lfo.Suffix = jcd.Suffix
)

, RunningOpCost AS (
	SELECT 
		wuc.*,
		SUM(wuc.UnitOpCost) OVER(PARTITION BY wuc.Job, wuc.Suffix ORDER BY wuc.OperNum) RunningOpUnitCost --, wuc.AfterForge

	FROM WithUnitCost wuc
)

SELECT 
	DATEPART(YEAR, j.ClosedDate) ClosedYear,
	DATEPART(MONTH, j.ClosedDate) ClosedMonth,
	j.Job, j.Suffix, j.Item, j.QtyComp, j.QtyScrp, j.TotalQty,
	roc.OperNum, roc.WC, roc.OpCompQty, roc.OpScrpQty,
	roc.AfterForge,
	roc.RunningOpUnitCost,
	(roc.RunningOpUnitCost * CASE WHEN roc.OpScrpQty > 0 THEN 1 ELSE 0 END) OpScrapUnitCost,
	(roc.RunningOpUnitCost * roc.OpScrpQty) OpScrapCost

FROM RunningOpCost roc
JOIN #Jobs j
	ON j.Job = roc.Job AND j.Suffix = roc.Suffix
ORDER BY
	j.job, j.Suffix, roc.OperNum
;
