-- there are two types of intake extaction: plain intake and real time.
-- we extract intake both ways and then we add them, in the end we combine mv and cv prioritizing metavision data
--
-- # About real time intake extraction:
-- This query extracts Real-time input from metavision MIMICIII on the first 24 hrs of admission
-- Records with no rate = STAT
-- Records with rate = INFUSION
-- fluids corrected for tonicity
-- This code is based on the notebook by Komorowski available at https://github.com/matthieukomorowski/AI_Clinician/blob/0438a66de7c5270e84a7fa51d78f56cd934ad240/AIClinician_Data_extract_MIMIC3_140219.ipynb
-- total equiv volume is in ML
-- rate units is mL/hour
--
--
--
--
--
--
--
--################### METAVISION query starts here
WITH
  metavision_intake_one AS (
  SELECT
    mv.icustay_id,
    mv.starttime AS charttime
    -- standardize the units to millilitres
    -- also metavision has floating point precision.. but we only care down to the mL
    ,
    ROUND(CASE
        WHEN mv.amountuom = 'L' THEN mv.amount * 1000.0
        WHEN mv.amountuom = 'ml' THEN mv.amount
      ELSE
      NULL
    END
      ,2) AS amount
  FROM
    `physionet-data.mimiciii_clinical.inputevents_mv` mv
  WHERE
    mv.itemid IN (
      225943, -- Solution
      225158, -- NaCl 0.9%
      225828, -- LR
      225944,-- Sterile Water
      225797, -- Free Water
      225159,-- NaCl 0.45%
      225161, -- NaCl 3% (Hypertonic Saline)
      225823, -- D5 1/2NS
      225825, -- D5NS
      225827, -- D5LR
      225941, -- D5 1/4NS
      226089 -- Piggyback
      )
    AND mv.statusdescription != 'Rewritten' AND
    -- in MetaVision, these ITEMIDs appear with a null rate IFF endtime=starttime + 1 minute
    -- so it is sufficient to:
    --    (1) check the rate is > 240 if it exists or
    --    (2) ensure the rate is null and amount > 240 ml
    ( (mv.rate IS NOT NULL
        AND mv.rateuom = 'mL/hour')
      OR (mv.rate IS NOT NULL
        AND mv.rateuom = 'mL/min')
      OR (mv.rate IS NULL
        AND mv.amountuom = 'L')
      OR (mv.rate IS NULL
        AND mv.amountuom = 'ml') ) ),
    
  metavision_intake_final AS(
  SELECT
    icustay_id,
    charttime,
    SUM(amount) AS intake_first,
    DATETIME_DIFF(charttime, INTIME, MINUTE) AS chartoffset
  FROM
    metavision_intake_one
  LEFT JOIN
    `physionet-data.mimiciii_clinical.icustays`
  USING
    (icustay_id)
    -- just because the rate was high enough, does *not* mean the final amount was
  WHERE
  icustay_id IS NOT NULL
  GROUP BY
    metavision_intake_one.icustay_id,
    metavision_intake_one.charttime,
    INTIME),


-- metavision realtime starts here
metavision_realtime_one AS (
  SELECT
    icustay_id,
    DATETIME_DIFF(starttime, INTIME, MINUTE) AS starttime,
    DATETIME_DIFF(endtime, INTIME, MINUTE) AS endtime,
    itemid,
    amount,
    rate,
    CASE
      WHEN itemid IN (30176, 30315) THEN amount *0.25
      WHEN itemid IN (30161) THEN amount *0.3
      WHEN itemid IN (30020, 30015
      --, 225823
      , 30321, 30186, 30211, 30353, 42742, 42244
      --, 225159
      ) THEN amount*0.5 --
      WHEN itemid IN (227531) THEN amount *2.75
      WHEN itemid IN (30143
      --, 225161
      ) THEN amount*3
      WHEN itemid IN (30009, 220862) THEN amount *5
      WHEN itemid IN (30030, 220995, 227533) THEN amount *6.66
      WHEN itemid IN (228341) THEN amount *8
    ELSE
    amount
  END
    AS tev, -- total equivalent volume
    DATETIME_DIFF(starttime, INTIME, MINUTE) AS chartoffset
  FROM
    `physionet-data.mimiciii_clinical.inputevents_mv` inputevents_mv
  LEFT JOIN
    `physionet-data.mimiciii_clinical.icustays`
  USING
    (icustay_id)  
    -- only real time items !!
  WHERE
    icustay_id IS NOT NULL
    AND amount IS NOT NULL
    AND itemid IN (
    -- we are comenting the items appearing in metavision_intake_one
    --225158
    --,225943
    --,226089
       225168
    --,225828
    ,225823,220862,220970,220864,225159,220995,225170,
    --225825,
    227533,225161,227531,225171
    --,225827
    --,225941
    ,225823,225825,225941,225825,228341,225827,30018,30021,30015,30296,30020,30066,30001,30030,30060,30005,30321,30006,30061,30009,30179,30190,30143,30160,30008,30168,30186,30211,30353,30159,30007,30185,30063,30094,30352,30014,30011,30210,46493,45399,46516,40850,30176,30161,30381,30315,42742,30180,46087,41491,30004,42698,42244)
    ), 
real_time_derived_infusion AS(      
SELECT
  icustay_id,
  starttime,
  endtime,
  endtime - starttime AS infusion_duration_hrs,
  chartoffset,
  itemid,
  ROUND(CAST(amount AS numeric),3) AS amount,
  ROUND(CAST(rate AS numeric),3) AS rate,
  ROUND(CAST(tev AS numeric),3) AS tev, -- total equiv volume
  ROUND(CASE WHEN rate IS NOT NULL THEN (rate/1000)*((endtime-starttime)/60) 
       ELSE NULL
  END,2) AS intake_ltrs_per_hr
FROM
  metavision_realtime_one
ORDER BY
  icustay_id,
  starttime,
  itemid
  ), metavision_realtime_final AS (
 SELECT
    icustay_id,
    chartoffset,
    SUM(CASE WHEN rate IS NULL THEN tev ELSE rate*((endtime-starttime)/60) END) AS intake_real_time_mv
 FROM 
    real_time_derived_infusion
 WHERE
 intake_ltrs_per_hr <= 10 --extreme INTAKE = outliers = to be deleted (>10 litres of intake per 4h!!
 GROUP BY
    icustay_id,
    chartoffset
 ORDER BY  
    icustay_id,
    chartoffset
),
-- BEGINING OF metavision_two_ways
 metavision_two_ways AS(
 SELECT
 icustays.icustay_id,
  -- we are prioritizing intake first data over real time data
  -- in the end we decided to get rid of real time data
/* null + a = null so coalesce does the trick */
 ROUND(
 --COALESCE (
 SUM(COALESCE(intake_first,0))
 --, SUM (COALESCE(intake_real_time_mv,0) )
 ,2)
 --)
 AS intake_mv 
FROM
 `physionet-data.mimiciii_clinical.icustays` icustays
LEFT JOIN
 metavision_realtime_final
ON
  (icustays.icustay_id = metavision_realtime_final.icustay_id) AND metavision_realtime_final.chartoffset BETWEEN -6*60 AND 36*60 
LEFT JOIN
 metavision_intake_final
ON
  (icustays.icustay_id = metavision_intake_final.icustay_id) AND metavision_intake_final.chartoffset BETWEEN -6*60 AND 36*60
WHERE
  intake_real_time_mv IS NOT NULL 
OR
  intake_first IS NOT NULL 
GROUP BY 
    icustays.icustay_id
    ),
--################### CAREVUE query starts here
  careveu_intake_final AS (
  SELECT
    icustay_id,
    DATETIME_DIFF(charttime, INTIME, MINUTE) AS chartoffset, 
    SUM(ROUND(cv.amount,2)) AS intake_first_cv -- carevue always has units IN millilitres
  FROM
    `physionet-data.mimiciii_clinical.inputevents_cv` cv
 LEFT JOIN
    `physionet-data.mimiciii_clinical.icustays`
  USING
    (icustay_id)  
  WHERE
    cv.itemid IN
    (
      30015, -- "D5/.45NS" -- mixed colloids and crystalloids 
      30018, -- .9% Normal Saline
      30020, -- .45% Normal Saline 
      30021, -- Lactated Ringers
      30058, -- Free Water Bolus
      30060, -- D5NS
      30061, -- D5RL
      30063, -- IV Piggyback
      30065, -- Sterile Water --
      30143, -- 3% Normal Saline
      30159, -- D5 Ringers Lact.
      30160, -- D5 Normal Saline
      30169, -- Sterile H20_GU
      30190, -- NS .9%
      40850, -- ns bolus
      41491, -- fluid bolus
      42639, -- bolus
      42187, -- free h20
      43819, -- 1:1 NS Repletion.
      41430, -- free water boluses
      40712, -- free H20
      44160, -- BOLUS
      42383, -- cc FOR cc replace
      42297, -- Fluid bolus
      42453, -- Fluid Bolus
      40872, -- free water
      41915, -- FREE WATER
      41490, -- NS bolus
      46501, -- H2O Bolus
      45045, -- WaterBolus
      41984, -- FREE H20
      41371, -- ns fluid bolus
      41582, -- free h20 bolus
      41322, -- rl bolus
      40778, -- Free H2O
      41896, -- ivf boluses
      41428, -- ns .9% bolus
      43936, -- FREE WATER BOLUSES
      44200, -- FLUID BOLUS
      41619, -- frfee water boluses
      40424, -- free H2O
      41457, -- Free H20 intake
      41581, -- Water bolus
      42844, -- NS fluid bolus
      42429, -- Free water
      41356, -- IV Bolus
      40532, -- FREE H2O
      42548, -- NS Bolus
      44184, -- LR Bolus
      44521, -- LR bolus
      44741, -- NS FLUID BOLUS
      44126, -- fl bolus
      44110, -- RL BOLUS
      44633, -- ns boluses
      44983, -- Bolus NS
      44815, -- LR BOLUS
      43986, -- iv bolus
      45079, -- 500 cc ns bolus
      46781, -- lr bolus
      45155, -- ns cc/cc replacement
      43909, -- H20 BOlus
      41467, -- NS IV bolus
      44367, -- LR
      41743, -- water bolus
      40423, -- Bolus
      44263, -- fluid bolus ns
      42749, -- fluid bolus NS
      45480, -- 500cc ns bolus
      44491, -- .9NS bolus
      41695, -- NS fluid boluses
      46169, -- free water bolus.
      41580, -- free h2o bolus
      41392, -- ns b
      45989, -- NS Fluid Bolus
      45137, -- NS cc/cc
      45154, -- Free H20 bolus
      44053, -- normal saline bolus
      41416, -- free h2o boluses
      44761, -- Free H20
      41237, -- ns fluid boluses
      44426, -- bolus ns
      43975, -- FREE H20 BOLUSES
      44894, -- N/s 500 ml bolus
      41380, -- nsbolus
      42671 -- free h2o 
      )
    AND cv.amountuom = 'ml'
GROUP BY
    icustay_id,
    DATETIME_DIFF(charttime, INTIME, MINUTE) ),
careveu_realtime_one AS(      
  SELECT
    icustay_id,
    DATETIME_DIFF(charttime, INTIME, MINUTE) AS chartoffset,
    itemid,
    amount,
    CASE
     -- we are comenting the items appearing IN careveu_intake_final
      WHEN itemid IN (30176, 30315) THEN amount *0.25
      WHEN itemid IN (30161) THEN amount *0.3
      WHEN itemid IN (
      --30020
          30321
      --, 30015
      , 225823, 30186, 30211, 30353, 42742, 42244, 225159, 225159, 225159) THEN amount *0.5
      WHEN itemid IN (227531) THEN amount *2.75
      WHEN itemid IN (30143, 225161) THEN amount *3
      WHEN itemid IN (30009, 220862) THEN amount *5
      WHEN itemid IN (30030, 220995, 227533) THEN amount *6.66
      WHEN itemid IN (228341) THEN amount *8
    ELSE
    amount
  END
    AS tev -- total equivalent volume
  FROM
    `physionet-data.mimiciii_clinical.inputevents_cv` inputevents_cv
    -- only RT itemids
  LEFT JOIN
    `physionet-data.mimiciii_clinical.icustays`
  USING
    (icustay_id)      
  WHERE
    amount IS NOT NULL
    AND itemid IN (225158,
      225943,
      226089,
      225168,
      225828,
      225823,
      220862,
      220970,
      220864,
      225159,
      220995,
      225170,
      225825,
      227533,
      225161,
      227531,
      225171,
      225827,
      225941,
      225823,
      225825,
      225941,
      225825,
      228341,
      225827,
      30018,
      30021,
      30015,
      30296,
      30020,
      30066,
      30001,
      30030,
      30060,
      30005,
      30321,
      30006,
      30061,
      30009,
      30179,
      30190,
      30143,
      30160,
      30008,
      30168,
      30186,
      30211,
      30353,
      30159,
      30007,
      30185,
      30063,
      30094,
      30352,
      30014,
      30011,
      30210,
      46493,
      45399,
      46516,
      40850,
      30176,
      30161,
      30381,
      30315,
      42742,
      30180,
      46087,
      41491,
      30004,
      42698,
      42244)
  ORDER BY
    icustay_id,
    charttime,
    itemid ),
 careveu_realtime_final AS (
SELECT
  icustay_id,
  chartoffset,
  itemid,
  ROUND(CAST(amount AS numeric),3) AS amount,
  ROUND(CAST(tev AS numeric),3) AS tev -- total equivalent volume
FROM
  careveu_realtime_one), 
careveu_two_ways AS(
 SELECT
 icustays.icustay_id,
 -- we are prioritizing intake first data over real time data
 -- in the end we decided to get rid of real time data
/* null + a = null so coalesce does the trick */
 ROUND(
 --COALESCE(
   SUM(COALESCE(intake_first_cv,0))
 --, SUM(COALESCE(tev,0))
 ,2)
 --) 
 AS intake_cv
FROM
 `physionet-data.mimiciii_clinical.icustays` icustays
LEFT JOIN
 careveu_realtime_final
ON
  (icustays.icustay_id = careveu_realtime_final.icustay_id) AND careveu_realtime_final.chartoffset BETWEEN -6*60 AND 36*60 
LEFT JOIN
 careveu_intake_final
ON
  (icustays.icustay_id = careveu_intake_final.icustay_id) AND careveu_intake_final.chartoffset BETWEEN -6*60 AND 36*60
WHERE
  tev IS NOT NULL 
OR
  intake_first_cv IS NOT NULL 
GROUP BY 
    icustays.icustay_id
    )
SELECT 
    icustay_id,
    -- we prefer mv data whenever it is available
    intake_mv,
    intake_cv,
    COALESCE (intake_mv, intake_cv)AS intakes_total
FROM
 `physionet-data.mimiciii_clinical.icustays` icustays
LEFT JOIN
    metavision_two_ways
USING 
    (icustay_id)
LEFT JOIN
    careveu_two_ways
USING 
    (icustay_id)
