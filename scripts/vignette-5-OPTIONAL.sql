/***************************************************************************************************
Asset:        Zero to Snowflake - アプリとコラボレーション
Version:      v2 (SQL 版)
Copyright(c): 2025 Snowflake Inc. All rights reserved.

┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ★★★ このセクションは【オプション】です ★★★                                                  │
│                                                                                                │
│  SWT ハンズオン（4 時間）の本編では時間の都合により扱いません。                                 │
│  当日は実施しませんので、ご興味があればハンズオン後にご自身のペースでお試しください。           │
│                                                                                                │
│  実行にはマーケットプレイスからのデータ取得（手動 UI 操作）が必要です。                         │
│  下記「事前準備」を完了してから SQL を実行してください。                                        │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

ストーリー:
  TastyBytes 社のジュニアアナリスト Ben の視点で、Snowflake マーケットプレイスの
  外部データ（気象・位置情報）と自社の売上データを組み合わせ、
  「天気がフードトラック売上に与える影響」を分析します。

目次:
  0. 事前準備 — マーケットプレイスからのデータ取得（UI 操作）
  1. セッションの初期設定
  2. 気象データの探索
  3. 気象データと売上データの統合
  4. 売上 × 天気の相関分析
  5. POI データと風速分析

前提条件:
  - setup.sql 実行済み（TastyBytes のデータベースとスキーマが構築済み）
  - ACCOUNTADMIN ロールでマーケットプレイスデータを取得できる権限
  - ウェアハウス TB_DE_WH が利用可能
  - 下記 0. の手順で ZTS_WEATHERSOURCE と ZTS_SAFEGRAPH を取得済み
***************************************************************************************************/


/*==================================================================================================
 0. 事前準備 — マーケットプレイスからのデータ取得（UI 操作）

   Snowflake マーケットプレイスを使うと、サードパーティのデータをコピーせずに
   リアルタイムで利用できます。ETL パイプラインの構築も不要です。

   ★ このセクションは Snowsight の UI 操作です。SQL では実行できません。
     以下 2 つのデータセットを取得してから、1. 以降の SQL に進んでください。
==================================================================================================*/

/*  0-1. Weather Source（気象データ）
    ------------------------------------------------------------------
    気温・降水量・風速などの日次気象データを提供するデータセット。

    1. 画面左下で ACCOUNTADMIN ロールに切り替える
    2. ナビゲーションメニューから「データ製品」→「マーケットプレイス」を開く
    3. 検索バーに `Weather Source frostbyte` と入力
    4. 「Weather Source LLC: frostbyte」を選択し「取得」をクリック
    5. 「オプション」を展開し、データベース名を ZTS_WEATHERSOURCE に変更
    6. アクセスを PUBLIC に付与して「完了」をクリック
*/

/*  0-2. Safegraph（POI: 位置情報データ）
    ------------------------------------------------------------------
    フードトラック設置場所周辺の施設情報（駐車場の有無、営業時間など）。

    1. 同様にマーケットプレイスで `safegraph frostbyte` を検索
    2. 「Safegraph: frostbyte」を選択し「取得」をクリック
    3. データベース名を ZTS_SAFEGRAPH に設定
    4. アクセスを PUBLIC に付与して「完了」をクリック
*/

-- 取得できたことを確認する（2 つのデータベースが表示されればOK）
SHOW DATABASES LIKE 'ZTS_%';


/*==================================================================================================
 1. セッションの初期設定
==================================================================================================*/

USE DATABASE tb_101;
USE ROLE tb_analyst;
USE WAREHOUSE tb_de_wh;


/*==================================================================================================
 2. 気象データの探索
   マーケットプレイスから取得した Weather Source データの中身を確認します。
==================================================================================================*/

/*  2-1. 米国都市ごとの気象概要
    ------------------------------------------------------------------
    気象データには都市ごとの風速・気温・降水量・降雪量などが含まれる。
    まずは米国の都市ごとの平均的な気象条件を確認する。
*/
SELECT
    DISTINCT city_name,
    ROUND(AVG(max_wind_speed_100m_mph), 1) AS avg_wind_speed_mph,
    ROUND(AVG(avg_temperature_air_2m_f), 1) AS avg_temp_f,
    ROUND(AVG(tot_precipitation_in), 2) AS avg_precipitation_in,
    ROUND(MAX(tot_snowfall_in), 2) AS max_snowfall_in
FROM ZTS_WEATHERSOURCE.onpoint_id.history_day
WHERE country = 'US'
GROUP BY city_name
ORDER BY avg_temp_f DESC;


/*==================================================================================================
 3. 気象データと売上データの統合
   Weather Source の気象データと TastyBytes の自社データ（国・都市情報）を結合し、
   気象データをビジネスの文脈で使える形に整理します。
==================================================================================================*/

/*  3-1. 日次気象ビューの作成
    ------------------------------------------------------------------
    気象データ × 郵便番号 × 国データを結合する。
*/
CREATE OR REPLACE VIEW TB_101.harmonized.daily_weather_v
COMMENT = 'Tasty Bytes がサービスを提供する都市に絞り込んだ Weather Source 日次過去データ'
    AS
SELECT
    hd.*,
    TO_VARCHAR(hd.date_valid_std, 'YYYY-MM') AS yyyy_mm,
    pc.city_name AS city,
    c.country AS country_desc
FROM ZTS_WEATHERSOURCE.onpoint_id.history_day hd
JOIN ZTS_WEATHERSOURCE.onpoint_id.postal_codes pc
    ON pc.postal_code = hd.postal_code
    AND pc.country = hd.country
JOIN TB_101.raw_pos.country c
    ON c.iso_country = hd.country
    AND c.city = hd.city_name;

/*  3-2. ハンブルクの2022年2月 日次平均気温
    ------------------------------------------------------------------
    作成したビューを使って、ドイツ・ハンブルクの気温推移を確認する。

    【可視化のヒント】
      結果ペインで「チャート」をクリック
        チャートタイプ: 折れ線グラフ
        X軸: DATE_VALID_STD
        Y軸: AVERAGE_TEMP_F
*/
SELECT
    dw.country_desc,
    dw.city_name,
    dw.date_valid_std,
    ROUND(AVG(dw.avg_temperature_air_2m_f), 1) AS average_temp_f
FROM TB_101.harmonized.daily_weather_v dw
WHERE dw.country_desc = 'Germany'
    AND dw.city_name = 'Hamburg'
    AND YEAR(date_valid_std) = 2022
    AND MONTH(date_valid_std) = 2
GROUP BY dw.country_desc, dw.city_name, dw.date_valid_std
ORDER BY dw.date_valid_std ASC;


/*==================================================================================================
 4. 売上 × 天気の相関分析
   気象データと注文データを組み合わせた分析用ビューを作成し、
   天気が売上にどう影響するかを調べます。
==================================================================================================*/

/*  4-1. 日次売上気象ビューの作成
    ------------------------------------------------------------------
    注文データ（orders_v）と日次気象データを結合する。
*/
CREATE OR REPLACE VIEW TB_101.analytics.daily_sales_by_weather_v
COMMENT = '日次気象指標と注文データを結合した分析ビュー'
AS
WITH daily_orders_aggregated AS (
    SELECT
        DATE(o.order_ts) AS order_date,
        o.primary_city,
        o.country,
        o.menu_item_name,
        SUM(o.price) AS total_sales
    FROM TB_101.harmonized.orders_v o
    GROUP BY ALL
)
SELECT
    dw.date_valid_std AS date,
    dw.city_name,
    dw.country_desc,
    ZEROIFNULL(doa.total_sales) AS daily_sales,
    doa.menu_item_name,
    ROUND(dw.avg_temperature_air_2m_f, 2) AS avg_temp_fahrenheit,
    ROUND(dw.tot_precipitation_in, 2) AS avg_precipitation_inches,
    ROUND(dw.tot_snowdepth_in, 2) AS avg_snowdepth_inches,
    dw.max_wind_speed_100m_mph AS max_wind_speed_mph
FROM TB_101.harmonized.daily_weather_v dw
LEFT JOIN daily_orders_aggregated doa
    ON dw.date_valid_std = doa.order_date
    AND dw.city_name = doa.primary_city
    AND dw.country_desc = doa.country
ORDER BY date ASC;

/*  4-2. シアトルの天候カテゴリ別 メニュー別平均売上比較
    ------------------------------------------------------------------
    降水量に基づいて天候を3カテゴリに分類し、メニュー別の平均日次売上を比較する。
    大雨日だけを見ても影響は判断できないため、晴れの日との差分を算出して
    天候の影響を定量化する。

      晴れ（Dry）        : 降水量 < 0.1 インチ
      小雨（Light Rain） : 0.1 ≤ 降水量 < 1.0 インチ
      大雨（Heavy Rain） : 降水量 ≥ 1.0 インチ

    【可視化のヒント】
      チャートタイプ: 棒グラフ
        X軸: MENU_ITEM_NAME
        Y軸: AVG_DAILY_SALES
        グループ: WEATHER_CATEGORY
*/
WITH categorized_sales AS (
    SELECT
        menu_item_name,
        daily_sales,
        CASE
            WHEN avg_precipitation_inches < 0.1 THEN '1_Dry'
            WHEN avg_precipitation_inches < 1.0 THEN '2_Light Rain'
            ELSE '3_Heavy Rain'
        END AS weather_category
    FROM TB_101.analytics.daily_sales_by_weather_v
    WHERE country_desc = 'United States'
        AND city_name = 'Seattle'
        AND daily_sales > 0
),
summary AS (
    SELECT
        menu_item_name,
        weather_category,
        ROUND(AVG(daily_sales), 2) AS avg_daily_sales,
        COUNT(*) AS day_count
    FROM categorized_sales
    GROUP BY menu_item_name, weather_category
),
dry_baseline AS (
    SELECT menu_item_name, avg_daily_sales AS dry_sales
    FROM summary
    WHERE weather_category = '1_Dry'
)
SELECT
    s.menu_item_name,
    s.weather_category,
    s.avg_daily_sales,
    s.day_count,
    d.dry_sales AS baseline_dry_sales,
    ROUND(s.avg_daily_sales - d.dry_sales, 2) AS sales_diff_vs_dry,
    ROUND((s.avg_daily_sales - d.dry_sales) / NULLIFZERO(d.dry_sales) * 100, 1) AS pct_change_vs_dry
FROM summary s
LEFT JOIN dry_baseline d ON s.menu_item_name = d.menu_item_name
ORDER BY s.menu_item_name, s.weather_category;


/*==================================================================================================
 5. POI データと風速分析
   Safegraph の POI（Point of Interest: 興味地点）データと気象データを組み合わせて、
   フードトラック設置場所の環境をより詳しく分析します。
==================================================================================================*/

/*  5-1. POI ビューの作成
    ------------------------------------------------------------------
    フードトラック設置場所に Safegraph の施設情報を結合する。
*/
CREATE OR REPLACE VIEW TB_101.harmonized.tastybytes_poi_v
COMMENT = 'フードトラック設置場所に Safegraph の POI 情報を結合したビュー'
AS
SELECT
    l.location_id,
    sg.postal_code,
    sg.country,
    sg.city,
    sg.iso_country_code,
    sg.location_name,
    sg.top_category,
    sg.category_tags,
    sg.includes_parking_lot,
    sg.open_hours
FROM TB_101.raw_pos.location l
JOIN zts_safegraph.public.frostbyte_tb_safegraph_s sg
    ON l.location_id = sg.location_id
    AND l.iso_country_code = sg.iso_country_code;

/*  5-2. 風速が最も高い場所 TOP 3（2022年・米国）
    ------------------------------------------------------------------
    各フードトラック設置場所の年間平均風速を計算し、最も過酷な環境の場所を特定する。
*/
SELECT TOP 3
    p.location_id,
    p.city,
    p.postal_code,
    ROUND(AVG(hd.max_wind_speed_100m_mph), 1) AS average_wind_speed
FROM TB_101.harmonized.tastybytes_poi_v AS p
JOIN ZTS_WEATHERSOURCE.onpoint_id.history_day AS hd
    ON p.postal_code = hd.postal_code
WHERE p.country = 'United States'
    AND YEAR(hd.date_valid_std) = 2022
GROUP BY p.location_id, p.city, p.postal_code
ORDER BY average_wind_speed DESC;

/*  5-3. ブランドの天候耐性分析: 穏やかな日 vs 風の強い日
    ------------------------------------------------------------------
    風速上位3か所で営業するフードトラックブランドについて、
    天候条件による売上の違いを比較する。

      穏やかな日   : 最大風速 ≤ 20 mph（約 32 km/h）
      風の強い日   : 最大風速 > 20 mph

    【ビジネス上の活用例】
      - 風に弱いブランドには「強風の日」限定プロモーションを実施
      - ブランドのメニュー構成を場所の気候特性に合わせて最適化
      - 新規出店時、天候耐性の高いブランドを風の強いエリアに優先配置
*/
WITH TopWindiestLocations AS (
    SELECT TOP 3
        p.location_id
    FROM TB_101.harmonized.tastybytes_poi_v AS p
    JOIN ZTS_WEATHERSOURCE.onpoint_id.history_day AS hd
        ON p.postal_code = hd.postal_code
    WHERE p.country = 'United States'
        AND YEAR(hd.date_valid_std) = 2022
    GROUP BY p.location_id, p.city, p.postal_code
    ORDER BY AVG(hd.max_wind_speed_100m_mph) DESC
),
BrandSales AS (
    SELECT
        o.truck_brand_name,
        ROUND(
            AVG(CASE WHEN hd.max_wind_speed_100m_mph <= 20 THEN o.order_total END),
            2) AS avg_sales_calm_days,
        ROUND(
            AVG(CASE WHEN hd.max_wind_speed_100m_mph > 20 THEN o.order_total END),
            2) AS avg_sales_windy_days
    FROM TB_101.analytics.orders_v AS o
    JOIN ZTS_WEATHERSOURCE.onpoint_id.history_day AS hd
        ON o.primary_city = hd.city_name
        AND DATE(o.order_ts) = hd.date_valid_std
    WHERE o.location_id IN (SELECT location_id FROM TopWindiestLocations)
    GROUP BY o.truck_brand_name
    HAVING avg_sales_calm_days IS NOT NULL
       AND avg_sales_windy_days IS NOT NULL
)
SELECT
    truck_brand_name,
    avg_sales_calm_days,
    avg_sales_windy_days,
    ROUND(avg_sales_windy_days - avg_sales_calm_days, 2) AS sales_diff,
    ROUND((avg_sales_windy_days - avg_sales_calm_days) / NULLIFZERO(avg_sales_calm_days) * 100, 1) AS pct_change
FROM BrandSales
ORDER BY ABS(pct_change) DESC;


/*==================================================================================================
 まとめ

 このセクションでは以下を実施しました:

   1. マーケットプレイス活用 — Weather Source と Safegraph のデータをコピーなしで即座に利用開始
   2. データ統合           — 外部の気象・POI データと自社の売上データを結合するビューを構築
   3. 天候カテゴリ別売上比較 — シアトルの降水量を晴れ・小雨・大雨に分類し、
                              メニュー別平均売上の差分を定量化
   4. ブランド天候耐性      — 風速条件によるブランド別売上差異を定量化

 さらなる発展:
   - 回帰分析（重回帰）で気温・降水量・風速の複合的な影響度を算出
   - 曜日・祝日・イベント情報を加えた多変量分析
   - 機械学習（時系列予測）で天気予報ベースの売上予測モデル構築

 参考:
   - Snowflake マーケットプレイス: https://docs.snowflake.com/ja/user-guide/data-sharing-intro
==================================================================================================*/


/*==================================================================================================
 (オプション) クリーンアップ
   作成したビューを削除する場合は以下のブロックを実行してください。
   マーケットプレイスから取得したデータベース（ZTS_WEATHERSOURCE / ZTS_SAFEGRAPH）は
   Snowsight の「データ製品」から削除できます。
==================================================================================================*/
/*
USE ROLE tb_admin;

DROP VIEW IF EXISTS TB_101.harmonized.tastybytes_poi_v;
DROP VIEW IF EXISTS TB_101.analytics.daily_sales_by_weather_v;
DROP VIEW IF EXISTS TB_101.harmonized.daily_weather_v;
*/
