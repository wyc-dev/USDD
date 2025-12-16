# USDD - Pantha Capital 收益型穩定幣 (Alpha)

**USDD** 係一個部署喺 **Base 鏈** 上嘅收益型穩定幣（yield-bearing stablecoin），代表由 Pantha Capital 管理嘅現實世界資產（RWA）代幣化投資組合。

用戶可以用 USDC 1:1 兌換鑄造 USDD，質押（stake）嚟賺取固定 APY 收益，同時享有推薦獎勵機制。贖回（redemption）需要手動由 owner 或操作經理履行，以確保資金安全同投資策略嘅靈活性。

## 主要特點

- **1:1 錨定 USDC**：存款即時轉入 vault，鑄造等量 USDD
- **固定質押收益**：全額質押模式，根據持有時間按 owner 設定嘅 APY 計算收益
- **推薦獎勵**：大額存款、小額贖回同每次 unstake 都會為推薦人鑄造額外 USDD 獎勵（固定 1%）
- **小額操作費用**：低於 `boundaryAmount`（默認 1000 USDD）嘅操作會收取基於當前 APY 嘅費用
- **早期 unstake 懲罰**：365 天內提前取出會收取線性遞減費用（VIP 地址豁免）
- **手動贖回機制**：用戶請求贖回後，owner 或授權操作經理（operation manager）從自己資金履行 USDC 返還
- **高度中心化但可控**：所有資金流向由 owner 同多位 operation manager 管理，適合受監管或需要靈活投資策略嘅 RWA 產品

## 合約地址（Base 鏈）

- USDD Token：`[待部署後填入]`
- USDC（Base 原生）：`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

## 使用方式

### 1. 存款（Deposit）
- 用 USDC approve 合約
- 調用 `depositUSDC(amount, referrer)` → 鑄造等量 USDD
- 若金額 ≥ 1000 USDD 且有推薦人，推薦人會額外獲得 1% USDD 獎勵

### 2. 質押（Stake）
- 用 USDD approve 合約
- 調用 `stakeUSDD(amount)` → 鎖定 USDD，開始計息
- 每次只允許一個質押位置（全額模式）

### 3. 取出（Unstake）
- 調用 `unstakeUSDD()` → 取回本金 + 收益獎勵
- 可能收取早期取出費或小額費，同時推薦人獲得 1% 獎勵

### 4. 贖回（Redemption）
- 調用 `requestRedemption(amount)` → 燒毀 USDD，進入待履行隊列
- owner 或 operation manager (後台bot) 調用 `fulfillRedemption(investor)` 把 USDC 返還給用戶

### 5. 管理功能（僅 Owner）
- 設定 APY 同最大早期取出費：`setAPYandFEE()`
- 更新 vault 地址：`setVault()`
- 設定 VIP（豁免早期取出費）：`setVIP()`
- 授權操作經理（可履行贖回）：`setOperationManager()`
- 提取合約內其他資產：`withdrawAssets()`

## 重要風險提示

- **高度依賴信任**：贖回依賴團隊履行，資金存放於可控嘅 vault
- **中心化管理**：多簽 owner 擁有強大權限（更改參數、提取資產等）
- **無自動收益分發**：收益係固定 APY，實際投資回報需由團隊鏈下實現
- **推薦獎勵會造成通脹**：每次大額存款、小額贖回、unstake 都會鑄新 USDD

建議用戶僅投入可承受風險嘅資金，並密切關注團隊公告同 vault 透明度。

## 安全措施

- 使用 OpenZeppelin 最新版庫（ERC20、Ownable、ReentrancyGuard、SafeERC20）
- 所有外部交互加 `nonReentrant`
- 使用 custom errors 節省 gas
- 常量使用 `immutable` 優化
- 已進行 gas 優化同靜態分析工具檢查

## 聯繫方式

安全聯繫郵箱：hopeallgood.unadvised619@passinbox.com
