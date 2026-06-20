--This query was developed for QA Team
--They were spending 1 to 2 hours to gather documents based on used jobs for a shipped order for each child component job
--This recursive SP have helped them reduce the actual documents gathering time to only 10 minutes.

ALTER PROCEDURE ue_SLA_GetUsedJobPoSp (
	@ParentItem			NVARCHAR(30),
	@ParentOrdNum		NVARCHAR(10) = NULL,
	@ParentOrdLineSuf	INT = NULL,
	@Item				NVARCHAR(30),
	@TRNNum				DECIMAL(18, 0),
	@QtyConsumed		DECIMAL(18, 5),
	@RefType			NVARCHAR(1),
	@Lvl				INT = 1
)

AS

--A	sAdjustment
--B	sCycleCount
--C	sSplit/Merge/Create
--D	sScrap
--F	sFinish
--G	sMisc.Issue
--H	sMisc.Receipt
--I	sIssue/WIPChange
--L	sTransferLoss
--M	sStockMove
--N	sLabor/NextOperation
--O	sOtherCost
--P	sPhysicalInventory
--R	sReceipt
--S	sShip
--T	sTransferOrder
--W	sWithdrawal/Return

BEGIN

	SET NOCOUNT ON;	

	IF OBJECT_ID('tempdb..#MyTable') IS NULL
	BEGIN
		CREATE TABLE #MyTable(
			Lvl					INT,
			LastTRNNum			DECIMAL(18, 0),
			ParentItem			NVARCHAR(30),
			ParentOrdNum		NVARCHAR(10),
			ParentOrdLineSuf	INT,
			Item				NVARCHAR(30),
			OrdType				NVARCHAR(1),
			OrdNum				NVARCHAR(10),
			OrdLineSuf			INT,
			OrdRel				INT,
			OrdRank				INT,
			HeatLot				NVARCHAR(100)
		)
	END;

	-- 2. Scoped Table Variables. Completely unique to THIS specific execution tier.
	-- Child procedures cannot see, append to, or truncate these.
	DECLARE @OrderData TABLE (
		LastTRNNum		DECIMAL(18, 0),
		ParentItem		NVARCHAR(30),
		Item			NVARCHAR(30),
		OrdType			NVARCHAR(1),
		OrdNum			NVARCHAR(10),
		OrdLineSuf		INT,
		OrdRel			INT,
		OrdRank			INT
	);

	DECLARE @JobMatlUsed TABLE (
		LastTRNNum		DECIMAL(18, 0),
		OrdNum			NVARCHAR(10),
		OrdLineSuf		INT,
		ParentItem		NVARCHAR(30),
		Item			NVARCHAR(30),
		QtyConsumed		DECIMAL(18, 5),
		RefType			NVARCHAR(1),
		MatlRank		INT
	);

	---THIS CHUNK WILL GET THE JOB/PO USED BASED ON ITEM, TRNNUM, QTYCONSUMED, REFTYPE---
	--IF OBJECT_ID('tempdb..#OrderData') IS NOT NULL DROP TABLE #OrderData;
	WITH MatlTRN AS (
		SELECT 
			mt.trans_num TRNNum,
			mt.item Item,
			mt.ref_type OrdType,
			mt.ref_num OrdNum,		
			mt.ref_line_suf OrdLineSuf,
			mt.ref_release OrdRel,
			mt.qty Qty,
			@QtyConsumed - SUM(mt.qty) OVER(PARTITION BY mt.item ORDER BY mt.trans_num DESC) OnHandQty,
			SUM(mt.qty) OVER(PARTITION BY mt.item ORDER BY mt.trans_num DESC) RunningQty

		FROM matltran_mst mt
		WHERE
			mt.item = @Item
			AND mt.trans_num < @TRNNum
			AND (mt.trans_type IN ('F', 'R', 'W') OR ((LTRIM(LOWER(mt.loc)) = 'stock') AND mt.trans_type IN ('A', 'B', 'G', 'H', 'P', 'S')))
			AND mt.qty <> 0
			AND mt.ref_type = (IIF(@RefType='M','J','P'))
	)

	, FinalMatlTRN AS (
		SELECT 
			mt.*,
			(CASE WHEN mt.OnHandQty > 0 THEN 1 ELSE 0 END) AS IsPositive,
			ROW_NUMBER() OVER(PARTITION BY (CASE WHEN mt.OnHandQty > 0 THEN 1 ELSE 0 END) ORDER BY mt.TRNNum DESC) QtyTypeRanked

		FROM MatlTRN mt
	)	
	
	, AllOrders AS (
		SELECT 
			MAX(fmt.TRNNum) LastTRNNum,
			@ParentItem ParentItem,
			fmt.Item,
			fmt.OrdType,
			fmt.OrdNum,
			fmt.OrdLineSuf,
			fmt.OrdRel
	
		FROM FinalMatlTRN fmt
		WHERE fmt.IsPositive = 1 OR (fmt.IsPositive = 0 AND fmt.QtyTypeRanked = 1)
		GROUP BY
			fmt.Item,
			fmt.OrdType,
			fmt.OrdNum,
			fmt.OrdLineSuf,
			fmt.OrdRel
	)

	, FilterJobsAndPos AS (
		SELECT 
			ao.*
		FROM AllOrders ao
		JOIN job_mst j		ON j.job = ao.OrdNum AND j.suffix = ao.OrdLineSuf AND j.item = @Item
		WHERE ao.OrdType = 'J'

		UNION ALL

		SELECT 
			ao.*
		FROM AllOrders ao
		--JOIN job_mst j		ON j.job = ao.OrdNum AND j.suffix = ao.OrdLineSuf AND j.item = @Item
		WHERE ao.OrdType = 'P'
	)

	INSERT INTO @OrderData (LastTRNNum, ParentItem, Item, OrdType, OrdNum, OrdLineSuf, OrdRel, OrdRank)
	SELECT 
			fjp.LastTRNNum,
			fjp.ParentItem,
			fjp.Item,
			fjp.OrdType,
			fjp.OrdNum,
			fjp.OrdLineSuf,
			fjp.OrdRel,
			ROW_NUMBER() OVER(PARTITION BY fjp.Item ORDER BY fjp.OrdNum DESC) OrdRank
	FROM FilterJobsAndPos fjp
	;
	----------------------------------------------------------------------------------

	DECLARE @RowCount AS INT = @@ROWCOUNT;
	DECLARE @CurRank AS INT = 1;
	DECLARE @CurRefType AS NVARCHAR(1) = '';

	---NOW FOR EACH JOB FOUND WE WILL TRY TO GET THE HEATLOT NUMBER AND STORE THAT IN THE TABLE---
	WHILE @CurRank <= @RowCount
	BEGIN
		
		DECLARE @HeatLotFound AS INT = 0;		
	
		--FINDS THE HEAT LOT USING IP RCVR--		
		WITH OrdData AS (
			SELECT DISTINCT od.*, ISNULL(tsth.lot, '') HeatLot
			FROM @OrderData od
			LEFT JOIN rs_qcrcvr_mst qrcv	ON qrcv.ref_num = od.OrdNum AND qrcv.ref_line = od.OrdLineSuf AND IIF(od.OrdType = 'J', qrcv.oper_Num, qrcv.ref_release) = od.OrdRel
			LEFT JOIN rs_qctesth_mst tsth	ON tsth.rcvr_num = qrcv.rcvr_num
			WHERE od.OrdRank = @CurRank
		)

		INSERT INTO #MyTable(Lvl, LastTRNNum, ParentItem, ParentOrdNum, ParentOrdLineSuf, Item, OrdType, OrdNum, OrdLineSuf, OrdRel, OrdRank, HeatLot)
		SELECT 
			@Lvl, 
			od.LastTRNNum, 
			od.ParentItem,
			@ParentOrdNum,
			@ParentOrdLineSuf,
			od.Item, 
			od.OrdType, 
			od.OrdNum, 
			od.OrdLineSuf, 
			od.OrdRel, 
			od.OrdRank, 
			STRING_AGG(ISNULL(od.HeatLot, ''), '') HeatLot

		FROM OrdData od
		GROUP BY od.LastTRNNum, od.ParentItem, od.Item, od.OrdType, od.OrdNum, od.OrdLineSuf, od.OrdRel, od.OrdRank
		;
		-------------------------------------

		SET @HeatLotFound = (SELECT COUNT(1) FROM #MyTable mt WHERE mt.OrdRank = @CurRank AND mt.Item = @Item AND mt.HeatLot <> ''); --AND mt.OrdType = 'M'

		---IF RCVR NOT FOUND THEN WE WILL GET THE MATERIAL FOR THE CURRENT JOB---
		IF @HeatLotFound = 0 AND @Lvl < 10
		BEGIN

			DELETE FROM @JobMatlUsed;

			INSERT INTO @JobMatlUsed (LastTRNNum, OrdNum, OrdLineSuf, ParentItem, Item, QtyConsumed, RefType, MatlRank)
			SELECT 
				od.LastTRNNum, 
				j.job OrdNum,
				j.suffix OrdLineSuf,
				j.item ParentItem, 
				jm.item Item, 
				jm.qty_issued QtyConsumed, 
				itm.p_m_t_code RefType, 
				ROW_NUMBER() OVER(PARTITION BY od.Item ORDER BY jm.sequence) MatlRank	
				
			FROM @OrderData od
			JOIN job_mst j			ON j.job = od.OrdNum AND j.suffix = od.OrdLineSuf
			JOIN jobmatl_mst jm		ON jm.job = od.OrdNum AND jm.suffix = od.OrdLineSuf -- AND jm.oper_num = od.OrdRel
			JOIN item_mst itm		ON itm.item = jm.item
			WHERE jm.matl_type = 'M' AND od.OrdRank = @CurRank
			;

			DECLARE @MatlCount AS INT = @@ROWCOUNT;
			DECLARE @CurMatlRank AS INT = 1;

			WHILE @CurMatlRank <= @MatlCount
			BEGIN
				--SELECT @@NESTLEVEL NestLvl, jm.* FROM @JobMatlUsed jm WHERE jm.MatlRank = @CurMatlRank;

				DECLARE @CurMatlLastTRNNum AS DECIMAL(18, 0)
				DECLARE @CurParentItem AS NVARCHAR(30)	
				DECLARE @CurMaterial AS NVARCHAR(30)	
				DECLARE @CurMatlQtyConsumed AS DECIMAL(18, 5)
				DECLARE @CurMatlRefType AS NVARCHAR(1)
				DECLARE @CurOrdNum AS NVARCHAR(10)
				DECLARE @CurOrdLineSuf AS INT
				;

				SELECT 
					@CurMatlLastTRNNum = jm.LastTRNNum, 
					@CurParentItem = jm.ParentItem, 
					@CurMaterial = jm.Item, 
					@CurMatlQtyConsumed = jm.QtyConsumed, 
					@CurMatlRefType = jm.RefType,
					@CurOrdNum = jm.OrdNum,
					@CurOrdLineSuf = jm.OrdLineSuf

				FROM @JobMatlUsed jm
				WHERE jm.MatlRank = @CurMatlRank;

				DECLARE @CurLvl AS INT = @Lvl + 1;

				--AGAIN CALLS SP ITSELF TO RECURSIVELY GET THE JOBS USED AS WELL AS HEAT LOT FOR THAT
				EXEC ue_SLA_GetUsedJobPoSp 
					@Lvl=@CurLvl,
					@ParentItem=@CurParentItem,
					@ParentOrdNum=@CurOrdNum,
					@ParentOrdLineSuf=@CurOrdLineSuf,
					@Item=@CurMaterial,
					@TRNNum=@CurMatlLastTRNNum,
					@QtyConsumed=@CurMatlQtyConsumed,
					@RefType=@CurMatlRefType
				;

				SET @CurMatlRank = @CurMatlRank + 1;

			END;

		END;
		-------------------------------------

		SET @CurRank = @CurRank + 1;

	END;
-----------------------------------------------------------------------------------------------

	IF @@NESTLEVEL = 1
	BEGIN
		SELECT DISTINCT 
			mt.*,
			pitm.description ParentItemDescr,
			citm.description ItemDescr

		FROM #MyTable mt
		JOIN item_mst pitm		ON pitm.item = mt.ParentItem
		JOIN item_mst citm		ON citm.item = mt.Item
		ORDER BY mt.Lvl, mt.ParentItem, mt.Item, mt.ParentOrdNum DESC, mt.ParentOrdLineSuf, mt.OrdRank
		;
		DROP TABLE #MyTable;
		PRINT('DROPPED TABLE');

		IF OBJECT_ID('tempdb..#OrderData') IS NOT NULL DROP TABLE #OrderData;
		IF OBJECT_ID('tempdb..#JobMatlUsed') IS NOT NULL DROP TABLE #JobMatlUsed;
	END;

END;
