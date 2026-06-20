IF OBJECT_ID('tempdb..#ShipData') IS NOT NULL DROP TABLE #ShipData;

WITH CoShip AS (
	SELECT 
		--ci.co_num CoNum,
		--ci.co_release CoRel,
		--ci.co_line CoLine,
		DATEPART(YEAR, cs.ship_date) ShipYear,
		DATEPART(MONTH, cs.ship_date) ShipMonth,
		DATEPART(WEEK, cs.ship_date) ShipWeek,
		ci.item Item,
		itm.matl_type MatlType,
		itm.p_m_t_code PMTCode,
		(ci.price / ISNULL(ih.exch_rate, ISNULL(co.exch_rate, 1))) Price,		
		cs.qty_shipped QtyShipped,	
		mt.trans_num TranNum

	
	FROM coitem_mst ci
	JOIN co_mst	co					ON co.co_num = ci.co_num
	JOIN co_ship_mst cs				ON cs.co_num = ci.co_num AND cs.co_release = ci.co_release AND cs.co_line = ci.co_line
	LEFT JOIN item_mst itm			ON itm.item = ci.item
	LEFT JOIN matltran_mst mt		ON mt.ref_num = cs.co_num AND mt.ref_release = cs.co_release AND mt.ref_line_suf = cs.co_line AND mt.qty = (cs.qty_shipped * -1) AND CAST(mt.trans_date AS DATE) = CAST(cs.ship_date AS DATE)
	LEFT JOIN inv_item_mst im		ON im.co_num = cs.co_num AND im.co_release = cs.co_release AND im.co_line = cs.co_line AND im.do_num = cs.do_num AND im.do_seq = cs.do_seq AND im.do_line = cs.do_line
	LEFT JOIN inv_hdr_mst ih		ON ih.inv_num = im.inv_num AND ih.inv_seq = im.inv_seq AND ih.do_num = im.do_num
	WHERE 
		cs.ship_date >= '2026-01-01' AND ci.price > 0
)

SELECT 
	cs.ShipYear,
	cs.ShipMonth,
	cs.ShipWeek,
	cs.Item,
	cs.Price,
	cs.MatlType,
	cs.PMTCode,
	SUM(cs.QtyShipped) QtyShipped,
	MAX(cs.TranNum) TranNum

INTO #ShipData 
FROM CoShip cs
--WHERE cs.Item = '10363F'
GROUP BY cs.ShipYear, cs.ShipMonth, cs.ShipWeek, cs.Item, cs.Price, cs.MatlType, cs.PMTCode
;

IF OBJECT_ID('tempdb..#JobData') IS NOT NULL DROP TABLE #JobData;

WITH JobData AS (
	SELECT 
		sd.TranNum MatlTRNNum,
		sd.QtyShipped,
		sd.Item,
		mt.ref_num Job,
		mt.ref_release OperNum,
		mt.ref_line_suf Suffix,
		mt.trans_num JobTRNNum,
		mt.qty Qty,
		CASE WHEN SUM(mt.Qty) OVER(PARTITION BY mt.item ORDER BY mt.trans_num DESC) >= sd.QtyShipped THEN 1 ELSE 0 END UsedForShipping

	FROM #ShipData sd
	JOIN matltran_mst mt	ON mt.item = sd.item AND mt.trans_num < sd.TranNum
	WHERE mt.trans_type = 'F' AND mt.loc IS NOT NULL AND sd.PMTCode = 'M'
)

, JobTRNRanked AS (
	SELECT 
		jd.*,
		ROW_NUMBER() OVER(PARTITION BY jd.MatlTRNNum, jd.Item, jd.UsedForShipping ORDER BY jd.JobTRNNum DESC) JobTRNRanked

	FROM JobData jd
)

, FinalJobs AS (
	SELECT 
		jtr.MatlTRNNum,
		jtr.QtyShipped,
		jtr.Item,
		jtr.Job,
		jtr.Suffix

	FROM JobTRNRanked jtr
	WHERE
		jtr.UsedForShipping = 0 OR (jtr.JobTRNRanked = 1 AND jtr.UsedForShipping = 1)
	GROUP BY
		jtr.MatlTRNNum,
		jtr.QtyShipped,
		jtr.Item,
		jtr.Job,
		jtr.Suffix
)

SELECT 
	fj.MatlTRNNum, 
	CAST(ROUND(AVG(j.wip_complete/j.qty_complete), 2) AS DECIMAL(18, 8)) CostPerPc
INTO #JobData
FROM FinalJobs fj
JOIN job_mst j		ON j.job = fj.job AND j.suffix = fj.Suffix
WHERE j.qty_complete > 0
GROUP BY fj.MatlTRNNum
;

IF OBJECT_ID('tempdb..#POData') IS NOT NULL DROP TABLE #POData;

WITH POData AS (
	SELECT 
		sd.TranNum MatlTRNNum,
		sd.QtyShipped,
		sd.Item,
		mt.ref_num PO,
		mt.ref_release PORelease,
		mt.ref_line_suf POLine,
		mt.trans_num POTRNNum,
		mt.qty Qty,
		CASE WHEN SUM(mt.Qty) OVER(PARTITION BY mt.item ORDER BY mt.trans_num DESC) >= sd.QtyShipped THEN 1 ELSE 0 END UsedForShipping

	FROM #ShipData sd
	JOIN matltran_mst mt	ON mt.item = sd.item AND mt.trans_num < sd.TranNum
	WHERE sd.PMTCode = 'P' AND mt.ref_type = 'P'
)

, POTRNRanked AS (
	SELECT 
		pd.*,
		ROW_NUMBER() OVER(PARTITION BY pd.MatlTRNNum, pd.Item, pd.UsedForShipping ORDER BY pd.POTRNNum DESC) POTRNRanked

	FROM POData pd
)

SELECT 
	po.MatlTRNNum,
	po.Item,
	AVG(poi.item_cost) POUnitCost

INTO #POData
FROM POTRNRanked po
JOIN poitem_mst poi		ON poi.po_num = po.PO AND poi.po_release = po.PORelease AND poi.po_line = po.POLine
WHERE po.UsedForShipping = 0 OR  (po.UsedForShipping = 1 AND po.POTRNRanked = 1)
GROUP BY po.MatlTRNNum, po.Item
;

WITH SalesData AS (
	SELECT 
		sd.*,
		ISNULL(jd.CostPerPc, ISNULL(pd.POUnitCost, itm.cur_u_cost)) UnitCost,
		(sd.Price * sd.QtyShipped) Rev,
		((ISNULL(jd.CostPerPc, ISNULL(pd.POUnitCost, itm.cur_u_cost))) * sd.QtyShipped) COGS

	FROM #ShipData sd
	LEFT JOIN #JobData jd	ON jd.MatlTRNNum = sd.TranNum
	LEFT JOIN #POData pd	ON pd.MatlTRNNum = sd.TranNum
	LEFT JOIN item_mst itm	ON itm.item = sd.Item
)

SELECT 
	sd.ShipYear,
	sd.ShipMonth,
	sd.ShipWeek,
	ROUND(SUM(sd.Rev), 2) Rev,
	ROUND(SUM(sd.COGS), 2) COGS,
	ROUND(SUM(sd.Rev), 2) - ROUND(SUM(sd.COGS), 2) Profit,
	((ROUND(SUM(sd.Rev), 2) - ROUND(SUM(sd.COGS), 2))/ ROUND(SUM(sd.Rev), 2)) * 100 Margin

FROM SalesData sd
GROUP BY sd.ShipYear, sd.ShipMonth, sd.ShipWeek