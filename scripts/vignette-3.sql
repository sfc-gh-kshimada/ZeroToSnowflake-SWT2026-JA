/***************************************************************************************************
Asset:        Zero to Snowflake - Horizon ガバナンス・ハンズオン (Vignette 3)
Version:      v1
Copyright(c): 2025 Snowflake Inc. All rights reserved.

このスクリプトでは Snowflake Horizon を使った PII データ保護を体験します:
  1. RBAC                — tb_data_steward カスタムロールを作成し最小権限を付与
  2. 自動分類 & PII タグ — 分類プロファイルで PII カラムを自動検出・タグ付け
  3. Dynamic Masking      — pii タグに紐付くマスキングポリシーで列値を難読化
  4. Row Access Policy    — ロールごとに参照可能な国を制限

以下は時間に余裕がある場合のオプションセクションです:
  5. (オプション) Data Metric Function — 組み込み / カスタム DMF でデータ品質をチェック
  6. (オプション) Trust Center         — アカウント全体のセキュリティ状態を監視 (UI 操作)

前提条件:
  - setup.sql 実行済み（tb_101 DB, raw_customer/governance スキーマ, tb_admin/tb_data_engineer 等のロール, tb_dev_wh ウェアハウス）
  - 実行ユーザーは ACCOUNTADMIN / SECURITYADMIN / USERADMIN を利用可能であること
  - 対象テーブル: tb_101.raw_customer.customer_loyalty

ポリシー設計方針:
  - ACCOUNTADMIN は緊急時アクセス用途として全ポリシーをバイパス（マスクなし・全行参照可）
  - Masking バイパス:    ACCOUNTADMIN, TB_ADMIN, TB_DATA_ENGINEER, TB_DATA_STEWARD
  - Row Access バイパス: ACCOUNTADMIN, TB_ADMIN, TB_DATA_ENGINEER, TB_DATA_STEWARD
****************************************************************************************************/

-- セッションの初期設定
ALTER SESSION SET query_tag = '{"origin":"sf_sit-is","name":"tb_zts","version":{"major":1, "minor":1},"attributes":{"is_quickstart":1, "source":"sql", "vignette": "governance_with_horizon"}}';

USE ROLE useradmin;
USE DATABASE tb_101;
USE WAREHOUSE tb_dev_wh;


/*==================================================================================================
 1. ロールとアクセス制御 (RBAC)
   最小権限の原則に基づき、ガバナンス専任のカスタムロール tb_data_steward を作成する。
==================================================================================================*/

-- 既存ロールの一覧確認
SHOW ROLES;

-- tb_data_steward ロールの作成
USE ROLE useradmin;
CREATE OR REPLACE ROLE tb_data_steward
    COMMENT = 'カスタムロール: ガバナンスオブジェクトを管理するデータスチュワード';

-- tb_data_steward への権限付与
USE ROLE securityadmin;

-- ウェアハウスの使用権限
GRANT OPERATE, USAGE ON WAREHOUSE tb_dev_wh TO ROLE tb_data_steward;

-- データベース・スキーマへのアクセス権限
GRANT USAGE ON DATABASE tb_101 TO ROLE tb_data_steward;
GRANT USAGE ON ALL SCHEMAS IN DATABASE tb_101 TO ROLE tb_data_steward;

-- raw_customer テーブルの参照権限と governance スキーマの全権限
GRANT SELECT ON ALL TABLES IN SCHEMA raw_customer TO ROLE tb_data_steward;
GRANT ALL ON SCHEMA governance TO ROLE tb_data_steward;
GRANT ALL ON ALL TABLES IN SCHEMA governance TO ROLE tb_data_steward;

-- タグ適用・自動分類・分類プロファイル作成の権限（Section 2 で使用）
GRANT APPLY TAG ON ACCOUNT TO ROLE tb_data_steward;
GRANT EXECUTE AUTO CLASSIFICATION ON SCHEMA raw_customer TO ROLE tb_data_steward;
GRANT DATABASE ROLE SNOWFLAKE.CLASSIFICATION_ADMIN TO ROLE tb_data_steward;
GRANT CREATE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE ON SCHEMA governance TO ROLE tb_data_steward;

-- データ品質モニタリングの権限（Section 5 オプション で使用）
-- 組み込み DMF の手動呼び出しには対象テーブルへの SELECT が必要
GRANT SELECT ON ALL TABLES IN SCHEMA raw_pos TO ROLE tb_data_steward;
-- 不正レコードを挿入して DMF の検知を確認するために INSERT が必要
GRANT INSERT ON TABLE raw_pos.order_detail TO ROLE tb_data_steward;
-- カスタム DMF を governance スキーマに作成するための権限
GRANT CREATE DATA METRIC FUNCTION ON SCHEMA governance TO ROLE tb_data_steward;

-- 現在のユーザーに tb_data_steward を付与
SET my_user = CURRENT_USER();
GRANT ROLE tb_data_steward TO USER IDENTIFIER($my_user);

-- 付与結果の確認
SHOW GRANTS TO ROLE tb_data_steward;

-- PII データの確認 (tb_data_steward は raw_customer.customer_loyalty を参照可能)
USE ROLE tb_data_steward;
SELECT TOP 100 * FROM raw_customer.customer_loyalty;


/*==================================================================================================
 2. 自動タグ付けと PII 分類
   分類プロファイル (auto_tag=true) で PII カラムを自動検出し pii タグを付与する。
==================================================================================================*/

-- Section 1 で必要な権限は付与済みのため、tb_data_steward で直接タグ・プロファイルを作成できる
USE ROLE tb_data_steward;

CREATE OR REPLACE TAG governance.pii
    ALLOWED_VALUES 'TRUE', 'FALSE'
    PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT;

-- 分類プロファイルの作成 (auto_tag を true にすることで PII カラムへ自動的にタグが付与される)

CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE
  governance.tb_classification_profile(
    {
      'minimum_object_age_for_classification_days': 0,
      'maximum_classification_validity_days': 30,
      'auto_tag': true
    });

-- タグマップ: 検出された PII セマンティックカテゴリに pii タグを自動付与
CALL governance.tb_classification_profile!SET_TAG_MAP(
  {'column_tag_map':[
    {
      'tag_name':'tb_101.governance.pii',
      'tag_value':'TRUE',
      'semantic_categories':['NAME', 'PHONE_NUMBER', 'POSTAL_CODE', 'DATE_OF_BIRTH', 'CITY', 'EMAIL']
    }]});


-- スキーマまたはデータベースに適用
-- データベース全体に適用する場合：
-- ALTER DATABASE tb_101 SET CLASSIFICATION_PROFILE = 'tb_101.governance.tb_classification_profile';
-- 特定スキーマに適用する場合：
-- ALTER SCHEMA tb_101.raw_customer SET CLASSIFICATION_PROFILE = 'tb_101.governance.tb_classification_profile';

-- customer_loyalty テーブルを自動分類 (実行に数秒かかります)
CALL SYSTEM$CLASSIFY('tb_101.raw_customer.customer_loyalty', 'tb_101.governance.tb_classification_profile');

-- タグ付け結果の確認 (apply_method = AUTO となっていれば自動タグ付け成功)
SELECT
    column_name,
    tag_database,
    tag_schema,
    tag_name,
    tag_value,
    apply_method
FROM TABLE(
    tb_101.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('tb_101.raw_customer.customer_loyalty', 'TABLE')
)
ORDER BY column_name, tag_database, tag_name;

/*==================================================================================================
 3. Dynamic Masking Policy (カラムレベルセキュリティ)
   pii タグに紐付くマスキングポリシーで、ACCOUNTADMIN / TB_ADMIN / TB_DATA_ENGINEER / TB_DATA_STEWARD 以外には PII を難読化する。
==================================================================================================*/

USE ROLE tb_data_steward;

-- 文字列型 PII 用 (TB 系ロールは生値を参照、その他は '****MASKED****' で表示)
CREATE OR REPLACE MASKING POLICY governance.mask_string_pii AS (original_value STRING)
RETURNS STRING ->
  CASE WHEN
    CURRENT_ROLE() NOT IN ('ACCOUNTADMIN', 'TB_ADMIN', 'TB_DATA_ENGINEER', 'TB_DATA_STEWARD')
    THEN '****MASKED****'
    ELSE original_value
  END;

-- DATE 型 PII 用 (TB 系ロールは生値を参照、その他は年初日に丸めて表示)
CREATE OR REPLACE MASKING POLICY governance.mask_date_pii AS (original_value DATE)
RETURNS DATE ->
  CASE WHEN
    CURRENT_ROLE() NOT IN ('ACCOUNTADMIN', 'TB_ADMIN', 'TB_DATA_ENGINEER', 'TB_DATA_STEWARD')
    THEN DATE_TRUNC('year', original_value)
    ELSE original_value
  END;

-- pii タグに両マスキングポリシーを関連付ける
ALTER TAG governance.pii SET
    MASKING POLICY governance.mask_string_pii,
    MASKING POLICY governance.mask_date_pii;

-- 動作確認 1: PUBLIC ロール → PII カラムがマスクされる
USE ROLE public;
SELECT TOP 100 * FROM raw_customer.customer_loyalty;

-- 動作確認 2: TB_ADMIN ロール → 元の値がそのまま表示される
USE ROLE tb_admin;
SELECT TOP 100 * FROM raw_customer.customer_loyalty;


/*==================================================================================================
 4. Row Access Policy (行レベルセキュリティ)
   us_analyst / ja_analyst の参照可能な行を国で制限する。
   TB 系ロール（TB_ADMIN / TB_DATA_ENGINEER / TB_DEV / TB_DATA_STEWARD）は全行参照可能。
==================================================================================================*/

USE ROLE tb_data_steward;

-- ポリシーマップテーブル: ロール ↔ 参照可能な国の対応表
-- マップに登録したロールのみ行が絞られる（TB系ロールはポリシー側でバイパス）
CREATE OR REPLACE TABLE governance.row_policy_map
    (role STRING, country_permission STRING);

-- us_analyst は 'United States' の行のみ参照可能
INSERT INTO governance.row_policy_map
    VALUES('us_analyst', 'United States');

-- ja_analyst は 'Japan' の行のみ参照可能
INSERT INTO governance.row_policy_map
    VALUES('ja_analyst', 'Japan');

-- 行アクセスポリシーの作成
-- バイパス: ACCOUNTADMIN / TB_ADMIN / TB_DATA_ENGINEER / TB_DATA_STEWARD は全行参照可能
-- マップ登録済み（us_analyst / ja_analyst）: 許可された国のみ
-- マップ未登録のその他ロール: 0 件
CREATE OR REPLACE ROW ACCESS POLICY governance.customer_loyalty_policy
    AS (country STRING) RETURNS BOOLEAN ->
        CURRENT_ROLE() IN ('ACCOUNTADMIN', 'TB_ADMIN', 'TB_DATA_ENGINEER', 'TB_DATA_STEWARD')
        OR EXISTS (
            SELECT 1
            FROM governance.row_policy_map rp
            WHERE UPPER(rp.role) = CURRENT_ROLE()
              AND rp.country_permission = country
        );

-- customer_loyalty テーブルの country カラムにポリシーを適用する
ALTER TABLE raw_customer.customer_loyalty
    ADD ROW ACCESS POLICY governance.customer_loyalty_policy ON (country);

-- 動作確認 1: US_ANALYST → 米国の顧客のみ表示される
USE ROLE us_analyst;
SELECT TOP 100 * FROM raw_customer.customer_loyalty;

-- 動作確認 2: JA_ANALYST → 日本の顧客のみ表示される
USE ROLE ja_analyst;
SELECT TOP 100 * FROM raw_customer.customer_loyalty;

-- 動作確認 3: TB_DATA_ENGINEER → バイパスのため全行参照可能
USE ROLE tb_data_engineer;
SELECT country, COUNT(*) AS cnt
FROM tb_101.raw_customer.customer_loyalty
GROUP BY country
ORDER BY cnt DESC;


/*==================================================================================================
 5. (オプション) データ品質モニタリング (Data Metric Functions)
   ガバナンスは「守る」だけでなく「データを信頼できる状態に保つ」ことも含む。
   Snowflake の Data Metric Function (DMF) で、テーブルの品質チェックを SQL で表現する。

   ★ このセクションはオプションです。時間がない場合はスキップしてください。

   公式ドキュメント:
   https://docs.snowflake.com/ja/user-guide/data-quality-intro
==================================================================================================*/

USE ROLE tb_data_steward;
USE WAREHOUSE tb_dev_wh;

/*  5-1. 組み込み DMF による即座の品質チェック
    ------------------------------------------------------------------
    Snowflake は SNOWFLAKE.CORE スキーマに組み込み DMF を用意している。
    定義不要で、関数を呼ぶだけで品質を測定できる。
    （組み込み DMF の USAGE は全ユーザーに付与済みのため追加設定は不要）

    注意: DMF の引数に指定できるのはテーブル・ビューなどの実オブジェクトのみ。
          CTE やサブクエリを渡すと「only supports table-like objects」エラーになる。
*/

-- 顧客 ID が NULL の割合（顧客紐付けの欠損率）
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT customer_id FROM raw_pos.order_header) AS null_customer_pct;

-- 注文 ID の重複数（主キーとして一意であるべき）
SELECT SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT order_id FROM raw_pos.order_header) AS duplicate_order_ids;

-- 注文金額の平均値（外れ値や単位誤りの兆候を掴む）
SELECT SNOWFLAKE.CORE.AVG(SELECT order_total FROM raw_pos.order_header) AS avg_order_total;

/*  5-2. カスタム DMF の作成
    ------------------------------------------------------------------
    組み込み DMF では表現できない「業務ルール違反」を検出したい場合は、
    カスタム DMF を作成する。

    ここでは「注文合計金額が 単価 × 数量 と一致しない」明細を検出する。
    DMF はテーブル型の引数を受け取り、数値をひとつ返す関数として定義する。
*/
CREATE OR REPLACE DATA METRIC FUNCTION governance.invalid_order_total_count(
    order_prices_t TABLE(
        order_total NUMBER,
        unit_price NUMBER,
        quantity INTEGER
    )
)
RETURNS NUMBER
AS
'SELECT COUNT(*)
 FROM order_prices_t
 WHERE order_total != unit_price * quantity';

-- 挿入前のベースラインを確認する（この件数が「正常時の水準」となる）
SELECT governance.invalid_order_total_count(
    SELECT price, unit_price, quantity FROM raw_pos.order_detail
) AS invalid_rows_before;

/*  5-3. わざと壊して検知させる
    ------------------------------------------------------------------
    単価 $5 の商品を 2 個注文したので合計は $10 が正しいが、
    合計金額を $5 として登録した不正な明細を挿入する。
    その後で DMF を呼び出し、違反が検知されることを確認する。
*/
INSERT INTO raw_pos.order_detail
SELECT
    904745399, -- 注文詳細 ID（他の演習と衝突しない値）
    459520442, -- 注文 ID
    52,        -- メニューアイテム ID
    NULL,
    0,
    2,         -- 数量
    5.0,       -- 単価
    5.0,       -- 合計金額（本来は 5.0 * 2 = 10.0 であるべき → 業務ルール違反）
    NULL;

-- DMF を再度呼び出すと、ベースラインより 1 件増えていることが確認できる
SELECT governance.invalid_order_total_count(
    SELECT price, unit_price, quantity FROM raw_pos.order_detail
) AS invalid_rows_after;

/*
    ここまでは DMF を「手動で呼び出して」品質を測定した。
    実運用では DMF をテーブルに関連付けてスケジュール実行し、
    データが変更されるたびに自動でチェックさせることができる
    （ALTER TABLE ... SET DATA_METRIC_SCHEDULE / ADD DATA METRIC FUNCTION）。
    スケジュール実行はサーバーレスコンピュートを消費するため、
    本ハンズオンでは手動呼び出しまでに留めている。

    参考: https://docs.snowflake.com/ja/user-guide/data-quality-intro
*/


/*==================================================================================================
 6. (オプション) Trust Center によるセキュリティ監視
   ここまではデータそのものを保護してきた。最後にアカウント全体のセキュリティ状態を確認する。

   Trust Center は Snowflake アカウントのセキュリティリスクを評価・監視する統合コンソール。
   スキャナーが MFA 未設定・過剰権限ロール・非アクティブユーザーなどを自動検出し、
   推奨される修復手順を提示する。

   ★ このセクションは Snowsight の UI 操作が主体のため、SQL は権限付与のみ。
     操作手順のスクリーンショットは README を参照してください。

   README (UI 手順・スクリーンショット):
   https://github.com/sfc-gh-kshimada/ZeroToSnowflake-SWT2026-JA/blob/main/README.md#トラストセンター

   公式ドキュメント:
   https://docs.snowflake.com/ja/user-guide/trust-center/overview
==================================================================================================*/

/*  6-1. Trust Center を操作するための権限付与
    ------------------------------------------------------------------
    TRUST_CENTER_ADMIN アプリケーションロールを持つロールだけが
    スキャナーパッケージの有効化と Findings の参照を行える。
*/
USE ROLE accountadmin;
GRANT APPLICATION ROLE SNOWFLAKE.TRUST_CENTER_ADMIN TO ROLE tb_admin;

USE ROLE tb_admin;

/*  6-2. Snowsight で Trust Center を開く（UI 操作）
    ------------------------------------------------------------------
    1. 左側ナビゲーションバーの「Monitoring」をクリック
    2. 「Trust Center」をクリック
*/

/*  6-3. スキャナーパッケージの有効化（UI 操作）
    ------------------------------------------------------------------
    デフォルトではほとんどのスキャナーパッケージが無効になっている。
    アカウントのセキュリティ態勢を確認するために有効化する。

    1. 「Scanner Packages」タブをクリック
    2. 「CIS Benchmarks」をクリック
    3. 「Enable Package」ボタンをクリック
    4. モーダルで Frequency を「Monthly」に設定し「Continue」をクリック
    5. 「Threat Intelligence」パッケージでも同じ手順を繰り返す
*/

/*  6-4. 検出結果の確認（UI 操作）
    ------------------------------------------------------------------
    スキャナーの実行完了までしばらく待ってから「Findings」タブを開く。

    - 重大度別の違反サマリーがダッシュボードに表示される
    - 下部のリストに各違反・重大度・検出したスキャナーが一覧表示される
    - 任意の違反をクリックすると、概要と推奨される修復手順が右ペインに開く

    ポイント: Violations（推奨設定から外れた持続的な状態）と
              Detections（不審なログインなど単発のイベント）の2種類がある。
*/

-- 演習を続ける場合はガバナンス用ロールに戻す
USE ROLE tb_data_steward;


/*==================================================================================================
 (オプション) クリーンアップ
   ハンズオン後に作成オブジェクトを削除する場合は以下のブロックを実行してください。
==================================================================================================*/
/*
USE ROLE accountadmin;

-- 検証用に挿入した不正レコードを削除
DELETE FROM tb_101.raw_pos.order_detail WHERE order_detail_id = 904745399;

-- カスタム DMF の削除
-- 引数の型は内部で正規化されるため、シグネチャ不一致でエラーになる場合は
-- SHOW DATA METRIC FUNCTIONS IN SCHEMA tb_101.governance; で実際の型を確認する
DROP DATA METRIC FUNCTION IF EXISTS tb_101.governance.invalid_order_total_count(
    TABLE(NUMBER, NUMBER, NUMBER));

-- Row Access Policy を解除して削除
ALTER TABLE tb_101.raw_customer.customer_loyalty
    DROP ROW ACCESS POLICY tb_101.governance.customer_loyalty_policy;
DROP ROW ACCESS POLICY IF EXISTS tb_101.governance.customer_loyalty_policy;
DROP TABLE IF EXISTS tb_101.governance.row_policy_map;

-- Masking Policy をタグから外して削除
ALTER TAG tb_101.governance.pii UNSET
    MASKING POLICY tb_101.governance.mask_string_pii,
    MASKING POLICY tb_101.governance.mask_date_pii;
DROP MASKING POLICY IF EXISTS tb_101.governance.mask_string_pii;
DROP MASKING POLICY IF EXISTS tb_101.governance.mask_date_pii;

-- 分類プロファイルとタグの削除
DROP SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE IF EXISTS tb_101.governance.tb_classification_profile;
DROP TAG IF EXISTS tb_101.governance.pii;

-- カスタムロールの削除
USE ROLE useradmin;
DROP ROLE IF EXISTS tb_data_steward;
*/
