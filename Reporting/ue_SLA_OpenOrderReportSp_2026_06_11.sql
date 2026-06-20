--This query was developed for Planning & Sales team.
--It pulls the Open Orders and Checks its supplies.
--It also pulls up status of the supplies and shows which one is critical.
--Previous query was using WHILE LOOP to get supplies which was performance heavy.
--Performance cost was reduced by 40%.
--For an average of 1000 open order lines Old Query was using around 15-18 seconds and New Query is using around 9-11 seconds

DECLARE @CustNumFrom AS NVARCHAR(10) = NULL;
DECLARE @CustNumTo AS NVARCHAR(10) = NULL;

DECLARE @DueDateFrom AS DATETIME = NULL;
DECLARE @DueDateTo AS DATETIME = NULL;

DECLARE @TimeFrame NVARCHAR(20) = NULL;
DECLARE @CustIsHQType AS INT = 0;

DECLARE @UseColorCode AS INT = 0;

--DECLARE @DemandID AS NVARCHAR(MAX) = '.24-0001130.00001.00000.COD'; 
--'.24-0001107.00001.00000.COD';
--'.26-0000567.00040.00000.COD';
--'.25-0000815.00001.00000.COD';
--'.25-0000374.00060.00000.COD';
--'.26-0000322.00003.00000.COD';

--Query Options Setup
BEGIN
	EXEC setsitesp 'Default', NULL;
	SET NOCOUNT ON;	
END;

--Older SP Execution for UseInventory and To Update PromiseDate
BEGIN TRY
	--allocate available inventory to open orders/transfer orders based on acknowledge date
	EXEC ue_sla_allocateavailableinventorysp;
	--knm convert
	--EXEC SLA_AllocateAvailableInventorySp

	--populate promise date uet
	--knm convert
	EXEC SLA_SetCoLinePromiseDateSp;
END TRY
BEGIN CATCH
END CATCH;

--Main Filter Parameters Setup
BEGIN
	SET @CustNumFrom = NULLIF(TRIM(@CustNumFrom), '');
	SET @CustNumTo = NULLIF(TRIM(@CustNumTo), '');
	SET @TimeFrame = NULLIF(LOWER(TRIM(@TimeFrame)), '');

	DECLARE @Today AS DATETIME = dbo.MidNightOf(GETDATE());
	DECLARE @LastWeek AS DATETIME =  dbo.MidNightOf(DATEADD(DAY, - 7, GETDATE()));
	DECLARE @DueDateCutOff AS DATETIME;

	SET @DueDateCutOff =
		CASE @TimeFrame
			WHEN 'overdue' THEN @Today
			WHEN 'twoweeks' THEN DATEADD(DAY, 14, @Today)
			WHEN 'onemonth' THEN DATEADD(MONTH, 1, @Today)
			WHEN 'twomonths' THEN DATEADD(MONTH, 2, @Today)
			ELSE DATEADD(YEAR, 5, @Today)	-- 'All'
		END;

	SET @CustNumFrom = ISNULL(dbo.ExpandKyByType('CustNumType', @CustNumFrom), dbo.LowCharacter());
	SET @CustNumTo = ISNULL(dbo.ExpandKyByType('CustNumType', @CustNumTo), dbo.HighCharacter());

	SET @DueDateFrom = ISNULL(@DueDateFrom, DATEADD(year, - 5, @Today))
	SET @DueDateTo = ISNULL(@DueDateTo, DATEADD(year, 5, @Today))

	IF @CustNumFrom = '14VMI'
		SET @CustNumFrom = 'VMI';

	IF @CustNumTo = '14VMI'
		SET @CustNumTo = 'VMI';
END;

-- HQ Customer Table setup.
BEGIN 
	IF OBJECT_ID('tempdb..#HqCustNums') IS NOT NULL DROP TABLE #HqCustNums;
	CREATE TABLE #HqCustNums(
		CustNum			NVARCHAR(10),
		PRIMARY KEY (CustNum)
	);
	IF @CustIsHQType <> 0
		BEGIN
			INSERT #HqCustNums (CustNum)
			SELECT 
				cust_num CustNum
			FROM dbo.custaddr ca(NOLOCK)
			WHERE ca.name LIKE 'HYDRO QUEBEC%'
				AND ca.cust_seq = 0;
		END;
END;

-- Filters Open Orders and Gets MatlPlanTag [If MatlPlanTag is NULL THEN It is not Planned]
BEGIN
	IF OBJECT_ID('tempdb..#CoDemands') IS NOT NULL DROP TABLE #CoDemands;

	SELECT 
		coi.co_num CoNum,
		coi.co_release CoRelease,
		coi.co_line CoLine,
		coi.item Item,
		coi.qty_ordered QtyOrdered,
		coi.qty_shipped QtyShipped,
		coi.due_date DueDate,
		(coi.qty_ordered - coi.qty_shipped) QtyRemaining,
		CASE WHEN mpdemand.MATLTAG IS NOT NULL THEN 1 ELSE 0 END DemandPlanned,
		o.ORDERID DemandID,
		mpdemand.ADJQTY DemandQty,
		mpdemand.MATLTAG DemandTag
	
	INTO #CoDemands
	FROM coitem_mst coi
	JOIN co_mst co						ON co.co_num = coi.co_num
	LEFT JOIN ORDER000_mst o			ON o.OrderRowPointer = coi.RowPointer
	LEFT JOIN MATLPLAN000_mst mpdemand	ON mpdemand.ORDERID = o.ORDERID AND mpdemand.MATERIALID = coi.item
	WHERE
		coi.stat IN ('P', 'O') AND co.type <> 'E' AND co.cust_num NOT LIKE 'VMI%'
		AND (coi.qty_ordered > 0 AND coi.qty_shipped < coi.qty_ordered)
		AND ISNULL(coi.due_date, @Today) <= @DueDateCutOff
		AND ISNULL(coi.due_date, @Today) >= @DueDateFrom AND ISNULL(coi.due_date, @Today) <= @DueDateTo	
		AND co.cust_num >= @CustNumFrom AND co.cust_num <= @CustNumTo
		-- NEW: Dynamic HQ Filter using EXISTS
		AND (
			(@CustIsHQType = 0)
			OR
			(@CustIsHQType = 1 AND EXISTS (SELECT 1 FROM #HqCustNums hq WHERE hq.CustNum = co.cust_num))
			OR
			(@CustIsHQType = -1 AND NOT EXISTS (SELECT 1 FROM #HqCustNums hq WHERE hq.CustNum = co.cust_num))
		)
		;
		--AND o.ORDERID = @DemandID;	
END;

-- Storing all the Material Planning Codes for the Root OrderID
BEGIN
	IF OBJECT_ID('tempdb..#DemanMatlPlanBase') IS NOT NULL DROP TABLE #DemanMatlPlanBase;

	SELECT 
		cd.DemandTag,
		mp.MATLTAG MatlTag,
		mp.MATERIALID Item,
		mp.PMATLTAG ParentMatlTag,
		mp.PJSID ParentJSID,
		jr.oper_num OperNum

	INTO #DemanMatlPlanBase
	FROM #CoDemands cd
	JOIN MATLPLAN000_mst mp		ON mp.ORDERID = cd.DemandID
	LEFT JOIN JOBSTEP000_mst js
		ON js.JSID = mp.PJSID
	LEFT JOIN jobroute_mst jr
		ON jr.RowPointer = js.RefRowPointer;
END;

-- Recursively Joining Parent with Childs and getting its Supplies using InvPlan000
BEGIN
	IF OBJECT_ID('tempdb..#DemandSupplyData') IS NOT NULL DROP TABLE #DemandSupplyData;

	WITH RecurCTE AS (
		SELECT 
			cd.DemandTag RootTag,
			0 ParentTag, --CASE WHEN mp.PMATLTAG = 0 THEN cd.DemandTag ELSE mp.PMATLTAG END
			dmp.ParentJSID,
			cd.DemandTag ChildTag,
			CAST(cd.Item AS NVARCHAR(30)) ChildItem,
			CAST('1' AS NVARCHAR(50)) Lvl,				
			CAST('1' AS NVARCHAR(50)) Depth

		FROM #CoDemands cd
		JOIN #DemanMatlPlanBase dmp		ON dmp.DemandTag = cd.DemandTag AND dmp.Item = cd.Item

		UNION ALL

		SELECT 
			rc.RootTag RootTag,
			rc.ChildTag ParentTag,
			mp.ParentJSID,
			mp.MATLTAG ChilTag,
			CAST(mp.Item AS NVARCHAR(30)) ChildItem,
			CAST((rc.Depth + '.' + CAST(mp.OperNum AS NVARCHAR(5)))  AS NVARCHAR(50)) Lvl,
			CAST((rc.Depth + '.' + CAST(mp.OperNum AS NVARCHAR(5)) + '.' + CAST(ROW_NUMBER() OVER(PARTITION BY rc.RootTag, mp.ParentJSID, rc.ChildTag ORDER BY mp.ParentJSID) AS NVARCHAR(20))) AS NVARCHAR(50)) Depth

		FROM #DemanMatlPlanBase mp
		JOIN RecurCTE rc		
			ON rc.ChildTag = mp.ParentMatlTag
	)

	SELECT 
		--rc.RootID,
		rc.RootTag,
		rc.ParentTag,
		rc.ChildTag,
		rc.ChildItem,
		rc.Lvl,
		rc.Depth,

		CASE
			WHEN ip.SCHTYPE = 1 THEN 'INV'
			WHEN ip.SCHTYPE = 8 THEN 'INF_SUP'
			ELSE ISNULL(NULLIF(LTRIM(ISNULL(mpsup.PROCPLANID, mp.PROCPLANID)), ''), mpsup.ORDERID) 
		END ProcPlanID,

		rc.ParentJSID,

		ISNULL(NULLIF(ip.SUPMATLTAG, 0), rc.ChildTag) SupTag,

		CASE ip.SCHTYPE
			WHEN 1 THEN 'INV'
			WHEN 7 THEN 'PUR'
			WHEN 8 THEN 'INF'
			WHEN 3 THEN CASE RIGHT(mpsup.ORDERID, 3) WHEN 'JOB' THEN 'JOB' WHEN 'POS' THEN 'PO' WHEN 'COD' THEN 'CO' ELSE NULL END
			WHEN 11 THEN 'PLN'
		
		END SupType,
		ip.SCHTYPE SupplyCode,
		mpsup.STARTDATE SupplyStartDate,
		mpsup.ENDDATE SupplyEndDate,

		ip.ORIGQTY,
		itm.infinite_part InfSupplyPart,
		CASE WHEN (mp.FLAGS & 1) > 0 THEN 1 ELSE 0 END SLCriticalPath

	INTO #DemandSupplyData
	FROM RecurCTE rc
	JOIN item_mst itm				ON itm.item = rc.ChildItem
	LEFT JOIN MATLPLAN000_mst mp	ON mp.MATLTAG = rc.ChildTag
	LEFT JOIN INVPLAN000_mst ip		ON ip.MATLTAG = rc.ChildTag
	LEFT JOIN MATLPLAN000_mst mpsup	ON mpsup.MATLTAG = ISNULL(NULLIF(ip.SUPMATLTAG, 0), rc.ChildTag)
	WHERE ip.SCHTYPE NOT IN (6);
END;

-- Getting SLACAN CritPath data
BEGIN
	IF OBJECT_ID('tempdb..#DemandSupplyCritData') IS NOT NULL DROP TABLE #DemandSupplyCritData;

	WITH ActualCritPath AS (
		SELECT 
			dsd.*,
			CASE 
				WHEN dsd.SupplyCode = 1 OR dsd.InfSupplyPart = 1 THEN 0
				ELSE ROW_NUMBER() OVER(PARTITION BY dsd.RootTag, dsd.Lvl ORDER BY dsd.SupplyEndDate DESC)
			END CriticalPath

		FROM #DemandSupplyData dsd
		WHERE
			NOT (dsd.SupplyCode = 1 OR dsd.InfSupplyPart = 1)
	)

	SELECT 
		dsd.*,
		ISNULL(cp.CriticalPath, 0) CriticalPath

	INTO #DemandSupplyCritData
	FROM #DemandSupplyData dsd
	LEFT JOIN ActualCritPath cp
		ON cp.RootTag = dsd.RootTag AND cp.ChildTag = dsd.ChildTag AND cp.Depth = dsd.Depth AND cp.SupTag = dsd.SupTag;
END;

--JOBs_ Getting all the All Supplies data based on Jobs
BEGIN	
	-- BASE Job Table -- Holds Job Data & Job Route Data
	IF OBJECT_ID('tempdb..#JobSupplyBase') IS NOT NULL DROP TABLE #JobSupplyBase;

	WITH JobSupplies AS (
		SELECT DISTINCT dsc.SupTag, dsc.ProcPlanID
		FROM #DemandSupplyCritData dsc
		WHERE dsc.SupType = 'JOB'
	)

	SELECT 
		js.*,
		jp.JSID,
		jr.job Job,
		jr.suffix Suffix,
		jobs.priority JobPriorityCode,
		j.qty_released QtyReleased,
		j.qty_complete QtyComplete,
		j.qty_scrapped QtyScrapped,
		jr.oper_num OperNum,
		jp.STARTDATE,
		jp.ENDDATE,
		jr.oper_num,
		jr.wc WC,
		jr.Uf_JobRouteOperDesc OperDesc,
		wc.outside WCOutside

	INTO #JobSupplyBase
	FROM JobSupplies js
	JOIN JOBPLAN000_mst jp		ON jp.MATLTAG = js.SupTag
	JOIN JOBSTEP000_mst jstep	ON jstep.PROCPLANID = js.ProcPlanID AND jstep.JSID = jp.JSID
	JOIN jobroute_mst jr		ON jr.RowPointer = jstep.RefRowPointer
	JOIN job_mst j				ON j.job = jr.job AND j.suffix = jr.suffix
	JOIN job_sch_mst jobs		ON jobs.job = j.job AND jobs.suffix = j.suffix
	JOIN wc_mst wc				ON wc.wc = jr.wc;

	-- Gets Purchase Orders linked to a job based on JobSupplyBase data
	BEGIN
		IF OBJECT_ID('tempdb..#JobPOSupplies') IS NOT NULL DROP TABLE #JobPOSupplies;

		WITH JobPOSupplies AS (
			SELECT 
				jsb.*,	
				jm.ref_num PoNum,
				jm.ref_release PoRel,
				jm.ref_line_suf PoLine,
				poi.due_date DueDate,
				ROW_NUMBER() OVER(PARTITION BY jsb.SupTag, jsb.job, jsb.suffix, jsb.OperNum ORDER BY poi.due_date DESC) LastDueDateRank

			FROM #JobSupplyBase jsb
			LEFT JOIN jobmatl_mst jm	ON jm.job = jsb.Job AND jm.suffix = jsb.Suffix AND jm.oper_num = jsb.OperNum AND jm.ref_type = 'P'
			LEFT JOIN poitem_mst poi	ON poi.po_num = jm.ref_num AND poi.po_release = jm.ref_release AND poi.item = jm.item --AND poi.po_line = jm.ref_line_suf
			WHERE jsb.WCOutside = 1
		)


		SELECT 
			jos.SupTag,
			jos.ProcPlanID,
			jos.JSID,
			jos.PoNum,
			jos.PoLine,
			jos.DueDate

		INTO #JobPOSupplies
		FROM JobPOSupplies jos
		WHERE jos.LastDueDateRank = 1;
	END;

	-- Joins the Purchase Order data with Routing and Creates Final Routing Description Data for a Supply
	BEGIN
		IF OBJECT_ID('tempdb..#JobRouteDesc') IS NOT NULL DROP TABLE #JobRouteDesc;

		WITH JobSupplyOpRanked AS (
			SELECT 
				jsb.*,
				CASE WHEN jsb.WCOutside = 1 THEN ISNULL(jps.PoNum, 'N/A') END PoNum,
				CAST(jps.DueDate AS DATE) DueDate,
				ROW_NUMBER() OVER(PARTITION BY jsb.SupTag, jsb.Job, jsb.Suffix ORDER BY jsb.OperNum) OperRanked

			FROM #JobSupplyBase jsb
			LEFT JOIN #JobPOSupplies jps	ON jps.SupTag = jsb.SupTag AND jps.ProcPlanID = jsb.ProcPlanID AND jps.JSID = jsb.JSID
		)

		, JobSupplyOpMaxRanked AS (
			SELECT 
				jso.*,
				MAX(jso.OperRanked) OVER(PARTITION BY jso.SupTag, jso.Job, jso.Suffix) MaxOperRanked

			FROM JobSupplyOpRanked jso
		)

		SELECT 
			jsor.SupTag,
			jsor.ProcPlanID,
	
			--At Op:- 10: S/C MACH (205623 - Due 2026-06-18), Rem Op:- 20: QC Pre GALVO , 30: GALV  (N/A), 40: QC S/C Galv , 50: STNCL , 60: STRENGTH 

			STRING_AGG (	
				CASE 
					WHEN jsor.OperRanked = 1 THEN 
						'(' + LTRIM(jsor.Job) + '-' + CAST(jsor.Suffix AS NVARCHAR(5)) + ') ' + IIF(jsor.JobPriorityCode IS NOT NULL, '['+ CAST(jsor.JobPriorityCode AS NVARCHAR(5)) + ']', '') +
							' Rel: ' + FORMAT(jsor.QtyReleased, 'N0') + 
							' Comp: ' + FORMAT(jsor.QtyComplete, 'N0') + 
							' Scrp: ' + FORMAT(jsor.QtyScrapped, 'N0') + 
							', ' 
						 + 'Ops:- ' 
					--WHEN jsor.MaxOperRanked > 1 AND jsor.OperRanked = 2 THEN 'Rem Ops:- '
					ELSE ''
				END +
				CAST(jsor.oper_num AS NVARCHAR(5)) + ': ' +
				jsor.OperDesc + '' +
				CASE
					WHEN jsor.WCOutside = 1 THEN ' (' + LTRIM(jsor.PoNum) + ISNULL(' - Due Date: ' + CAST(jsor.DueDate AS NVARCHAR(10)), '') + ')'
					ELSE ''
				END,
			', '
			) RouteDesc

		INTO #JobRouteDesc
		FROM JobSupplyOpMaxRanked jsor
		GROUP BY jsor.SupTag, jsor.ProcPlanID;
	END;
END;

--POs _ Getting all the Supplies based on POs
BEGIN
	IF OBJECT_ID('tempdb..#POSupplyBase') IS NOT NULL DROP TABLE #POSupplyBase;

	WITH POSupplies AS (
		SELECT DISTINCT 
			dsc.SupTag, 
			dsc.ProcPlanID,
			SUBSTRING(dsc.ProcPlanID, 2, 10) PoNum,
			CAST(SUBSTRING(dsc.ProcPlanID, 13, 5) AS INT) PoLine,
			CAST(SUBSTRING(dsc.ProcPlanID, 19, 5) AS INT) PoRelease

		FROM #DemandSupplyCritData dsc
		WHERE dsc.SupType = 'PO'
	)

	SELECT 
		ps.*,

		--(PO 205244-3, Ordered)  Ord: 40, Rcvd: 0, Scrp: 0, Rmng: 40. Due Date: 2026-07-01
		(
			'(PO ' + 
				LTRIM(poi.po_num) + '-' + 
				CAST(LTRIM(poi.po_line) AS NVARCHAR(10)) + ', ' + 
				CASE poi.stat WHEN 'O' THEN 'Ordered' WHEN 'P' THEN 'Planned' WHEN 'C' THEN 'Completed' WHEN 'F' THEN 'Filled' ELSE 'Other' END + 
			')  ' + 
			'Ord: ' + FORMAT(poi.qty_ordered, 'N0') + 
			', Rcvd: ' + FORMAT(poi.qty_received, 'N0') + 
			', Scrp: ' + FORMAT((poi.qty_rejected + poi.qty_returned), 'N0') + 
			', Rmng: ' + FORMAT((poi.qty_ordered - poi.qty_received - (poi.qty_rejected + poi.qty_returned)), 'N0') + 
			'. Due Date: ' + ISNULL(FORMAT(poi.due_date, 'yyyy-MM-dd'), 'N/A')
		) PoLineDesc

	INTO #POSupplyBase
	FROM POSupplies ps
	LEFT JOIN poitem_mst poi		ON poi.po_num = ps.PoNum AND poi.po_release = ps.PoRelease AND poi.po_line = ps.PoLine;
END;

-- This Filter Outs the Non Inventory Supplies and Creates a SupplyDescription
BEGIN 
	IF OBJECT_ID('tempdb..#FinalDemandSupply') IS NOT NULL DROP TABLE #FinalDemandSupply;

	SELECT 
		dscd.*,
		itm.description ChildDescription,
		CASE WHEN itm.p_m_t_code = 'P' THEN 1 ELSE 0 END IsPurchased,
		CASE dscd.SupType
			WHEN 'PLN' THEN IIF(itm.p_m_t_code = 'P', '(NEW PO) SHORT', '(NEW JOB) SHORT') --'(PLN ' + CAST(dscd.ChildTag AS NVARCHAR(10)) + ')' --'NEW JOB/PO'--
			WHEN 'JOB' THEN jrd.RouteDesc
			WHEN 'INV' THEN 'USE INVENTORY'
			WHEN 'PO' THEN psb.PoLineDesc
			WHEN 'CO' THEN IIF(itm.p_m_t_code = 'P', 'USE PLANNED PO', 'USE PLANNED JOB')
			WHEN 'INF' THEN IIF(itm.p_m_t_code = 'P', 'USE PLANNED PO', 'USE PLANNED JOB')
		END SupDesc

	INTO #FinalDemandSupply
	FROM #DemandSupplyCritData dscd
	LEFT JOIN #JobRouteDesc jrd			ON jrd.SupTag = dscd.SupTag AND jrd.ProcPlanID = dscd.ProcPlanID
	LEFT JOIN #POSupplyBase psb			ON psb.SupTag = dscd.SupTag AND psb.ProcPlanID = dscd.ProcPlanID
	LEFT JOIN item_mst itm				ON itm.item = dscd.ChildItem
	WHERE dscd.SupplyCode <> 1;
END;

-- This Will Build the Whole Supply String for the Root Item
BEGIN
	IF OBJECT_ID('tempdb..#RootTagSupplyData') IS NOT NULL DROP TABLE #RootTagSupplyData;

	WITH RootTagSupplyData AS (
		SELECT 
			fds.RootTag,
			fds.Depth,
			(
				fds.ChildItem + ' (' + fds.ChildDescription + ') ' + IIF(fds.SLCriticalPath = 1, '{C} ', '') + --CHAR(13) + CHAR(10) +
				--+ '   ' + CAST(ROW_NUMBER() OVER(PARTITION BY fds.RootTag, fds.Depth ORDER BY fds.SupTag) AS NVARCHAR(5)) + '. ' + 
				+ FORMAT(fds.ORIGQTY, 'N0') + ' from ' + fds.SupDesc + '. '
			) RootTagSupplyData
			
			--,

			--CASE 
			--	WHEN fds.SLCriticalPath = 1 THEN 
			--		(
			--			fds.ChildItem + ' (' + fds.ChildDescription + ') ' + --CHAR(13) + CHAR(10) +
			--			--+ '   ' + CAST(ROW_NUMBER() OVER(PARTITION BY fds.RootTag, fds.Depth ORDER BY fds.SupTag) AS NVARCHAR(5)) + '. ' + 
			--			+ FORMAT(fds.ORIGQTY, 'N0') + ' from ' + fds.SupDesc + '. '
			--		)
			--	ELSE NULL 
			--END CritRootTagSupplyData

		FROM #FinalDemandSupply fds
	)

	SELECT 
		rtsd.RootTag,

		STRING_AGG (
			rtsd.RootTagSupplyData,
			CHAR(13) + CHAR(10)
		) WITHIN GROUP (ORDER BY rtsd.Depth) RootTagSupplyData
		
		--,

		--STRING_AGG (
		--	rtsd.CritRootTagSupplyData,
		--	CHAR(13) + CHAR(10)
		--) WITHIN GROUP (ORDER BY rtsd.Depth) CritRootTagSupplyData

	INTO #RootTagSupplyData
	FROM RootTagSupplyData rtsd
	GROUP BY rtsd.RootTag;
END;

-- FINAL SELECT
WITH FinalRootSupplyData AS (
	SELECT 
		cd.*,	
		ISNULL(ui.InvQty, 0) UseInvQty,

		--CASE
		--	WHEN cd.DemandPlanned = 0 THEN 'NOT PLANNED'
		--	ELSE 
		--		CASE
		--			WHEN ISNULL(ui.InvQty, 0) >= cd.QtyRemaining THEN 'USING STOCK'
		--			ELSE ISNULL(rtsd.CritRootTagSupplyData, 'PLEASE CHECK SUPPLIES')
		--		END
		--END CritRootTagSupplyData,

		CASE
			WHEN cd.DemandPlanned = 0 THEN 'NOT PLANNED'
			ELSE ISNULL(rtsd.RootTagSupplyData, 'PLEASE CHECK SUPPLIES')
		END RootTagSupplyData

	FROM #CoDemands cd
	LEFT JOIN #RootTagSupplyData rtsd	ON rtsd.RootTag = cd.DemandTag
	LEFT JOIN (
		SELECT 
			dscd.RootTag,
			SUM(dscd.ORIGQTY) InvQty

		FROM #DemandSupplyCritData dscd
		WHERE dscd.SupplyCode = 1 AND dscd.Lvl = '1'
		GROUP BY dscd.RootTag
	) ui
		ON ui.RootTag = cd.DemandTag
)

--p planning column
--c sales column

SELECT 
	coi.Uf_EXPforPlanning Expedited,	--p
	frsd.CoNum,						--pc
	c.cust_po CustPO,				--c
	coi.UF_CO_POTagNo PoLineTagNo,	--c
	frsd.Item,						--pc
	coi.cust_item CustItem,			--c
	itm.Uf_ItemCatalogue Cat,		--c
	itm.description Description,	--pc
	frsd.CoLine,					--pc	
	c.cust_num Cust,				--pc
	ca.name CustName,				--pc
	c.contact Contact,				--c
	ISNULL(LEFT(cust.Uf_CustDeliveryDayOfWeek, 3), '') DeliveryDay,					--pc
	frsd.QtyShipped,				--pc
	frsd.QtyRemaining QtyOwing,		--pc
	IIF((ISNULL(coi.Uf_CoShipPartial, 0) = 0 OR ISNULL(c.ship_partial, 0) = 0), 1, 0) NoPartialShipments,			--pc
	dbo.maxqty(ISNULL(itm.Uf_ItemStandardPackageOut, 0), 1) OuterPkgSize,				--pc

	-- ADDED BY: ROLVIN D. PAGUNSAN
	IIF(
		us.qtyusefromstock = 0, 
		'', 
		IIF(
			us.qtyusefromstock >= (coi.qty_ordered_conv - coi.qty_shipped), 
			'STOCK', 
			FORMAT(us.qtyusefromstock, 'N0')
			)
		) UseInventory, --pc

	--IIF(frsd.UseInvQty >= frsd.QtyRemaining, 'STOCK', FORMAT(frsd.UseInvQty, 'N0')) UseInventory,	--testing --pc


	--'MAIN' Whse,					--c	 --REMOVED NO LONGER NEEDED - Requested by Charmi
	
	CASE 
		WHEN EXISTS 
			(
				SELECT 1
				FROM ue_SLA_ShipSched ss (NOLOCK)
				WHERE ss.co_num = frsd.CoNum
					AND ss.co_line = frsd.CoLine
					AND ss.co_release = frsd.CoRelease
			)
			THEN 'YES'
		ELSE ''
	END PickSlip,					--pc

	--(
	--	SELECT TOP 1 pack_num
 --       FROM   pckitem
 --       WHERE  pckitem.co_num = coi.co_num
 --               AND pckitem.co_line = coi.co_line
 --               AND pckitem.co_release = coi.co_release
 --       ORDER  BY pckitem.pack_num DESC
	--) PackSlip,					--pc	--REMOVED NO LONGER NEEDED - Requested by Charmi

	coi.price_conv Price,								--pc
	(coi.price_conv * frsd.QtyRemaining) SalesValue,	--pc

	c.order_date OrderDate,			--pc
	coi.promise_date RequestDate,	--pc

	coi.Uf_COPromiseDate PromiseDate, --pc


	coi.due_date DueDate,			--pc
	coi.projected_date SysProjectedDate,	--pc
	
	--coi.Uf_COAckDate AcknDate,		--pc --REMOVED NO LONGER NEEDED - Requested by Charmi

	CASE 
		--Original Code
		WHEN ISNULL(coi.stat, '') = 'P' THEN 0
		WHEN dbo.SLA_GetCoMaxProjected(coi.co_num, coi.co_line, coi.co_release) IS NULL then 0
		ELSE DATEDIFF(DAY, dbo.SLA_GetCoMaxProjected(coi.co_num, coi.co_line, coi.co_release), ISNULL(coi.uf_coackdate, coi.due_date))
	END Variance,						--c

	coi.Uf_COHQReceptionDate HQReceptionDate, --pc --only hq

	dbo.Sla_qoh(itm.item, 'MAIN') QtyAtMain,					--c
	--frsd.CritRootTagSupplyData,		--pc

	IIF
	(
		us.qtyusefromstock >= (coi.qty_ordered_conv - coi.qty_shipped), 
		'', 
		frsd.RootTagSupplyData
	) RootTagSupplyData		--pc --frsd.RootTagSupplyData
	
FROM FinalRootSupplyData frsd
JOIN co_mst c						ON c.co_num = frsd.CoNum
JOIN coitem_mst coi					ON coi.co_num = frsd.CoNum AND coi.co_line = frsd.CoLine
JOIN item_mst itm					ON itm.item = frsd.Item
JOIN customer_mst cust				ON cust.cust_num = c.cust_num AND cust.cust_seq = 0
JOIN custaddr_mst ca				ON ca.cust_num = c.cust_num AND ca.cust_seq = cust.cust_seq
LEFT JOIN ue_SLA_QtyUseFromStock us	ON us.co_num = frsd.CoNum AND us.co_release = frsd.CoRelease AND us.co_line = frsd.CoLine
WHERE
	itm.matl_type = 'M'
ORDER BY
	coi.due_date, frsd.CoNum, frsd.CoLine
;

--END
