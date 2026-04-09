use anchor_lang::prelude::*;

pub const PROCESSOR_SEED: &[u8] = b"processor";
pub const SUBSCRIPTION_SEED: &[u8] = b"subscription";
pub const PAYMENT_RECORD_SEED: &[u8] = b"payment_record";

pub const MAX_SUPPORTED_TOKENS: usize = 20;
pub const DEFAULT_BOUNTY_PER_RENEWAL: u64 = 10_000;
pub const MAX_BOUNTY_PER_TX: u64 = 3_000_000;

pub const DEFAULT_CO_OWNER_ONE_BPS: u16 = 4000;
pub const DEFAULT_CO_OWNER_TWO_BPS: u16 = 4000;
pub const DEFAULT_CO_OWNER_THREE_BPS: u16 = 2000;

pub const MIN_SUBSCRIPTION_PRICE: u64 = 1000;

#[account]
pub struct PledgrConfig {
    pub authority: Pubkey,
    pub co_owner_one: Pubkey,
    pub co_owner_two: Pubkey,
    pub co_owner_three: Pubkey,
    pub co_owner_one_bps: u16,
    pub co_owner_two_bps: u16,
    pub co_owner_three_bps: u16,
    pub supported_tokens: Vec<Pubkey>,
    pub total_processed: u64,
    pub total_subscriptions: u64,
    pub paused: bool,
    pub bounty_per_renewal: u64,
    pub max_bounty_per_tx: u64,
    pub bounty_enabled: bool,
    pub bump: u8,
}

impl PledgrConfig {
    pub const LEN: usize = 8
        + 32
        + 32
        + 32
        + 32
        + 2
        + 2
        + 2
        + (4 + (32 * MAX_SUPPORTED_TOKENS))
        + 8
        + 8
        + 1
        + 8
        + 8
        + 1
        + 1;

    pub fn is_token_supported(&self, token_mint: &Pubkey) -> bool {
        self.supported_tokens.contains(token_mint)
    }

    pub fn calculate_co_owner_split(&self, platform_amount: u64) -> (u64, u64, u64) {
        let co_owner_one = (platform_amount as u128)
            .checked_mul(self.co_owner_one_bps as u128)
            .unwrap_or(0)
            / 10000u128;
        let co_owner_two = (platform_amount as u128)
            .checked_mul(self.co_owner_two_bps as u128)
            .unwrap_or(0)
            / 10000u128;
        let co_owner_one = co_owner_one as u64;
        let co_owner_two = co_owner_two as u64;
        let co_owner_three = platform_amount
            .checked_sub(co_owner_one)
            .and_then(|v| v.checked_sub(co_owner_two))
            .unwrap_or(0);
        (co_owner_one, co_owner_two, co_owner_three)
    }
}

#[account]
pub struct Subscription {
    pub subscription_id: [u8; 32],
    pub creator: Pubkey,
    pub subscriber: Pubkey,
    pub price: u64,
    pub payment_token_mint: Pubkey,
    pub split_strategy: SplitStrategy,
    pub period_secs: u32,
    pub next_due: i64,
    pub grace_secs: u32,
    pub created_at: i64,
    pub last_charged: i64,
    pub status: SubscriptionStatus,
    pub total_paid: u64,
    pub payment_count: u64,
    pub trial_end_date: Option<i64>,
    pub auto_renewal_consent: AutoRenewalConsent,
    pub bump: u8,
}

impl Subscription {
    pub const LEN: usize = 8
        + 32
        + 32
        + 32
        + 8
        + 32
        + 1
        + 4
        + 8
        + 4
        + 8
        + 8
        + 1
        + 8
        + 8
        + 9
        + (1 + 8 + 8 + 32 + 8 + 8)
        + 1;

    pub fn is_already_charged_this_period(&self, current_time: i64) -> bool {
        if self.last_charged == 0 {
            return false;
        }
        if self.period_secs == 0 {
            return true;
        }
        current_time
            .checked_sub(self.last_charged)
            .map(|elapsed| elapsed < self.period_secs as i64)
            .unwrap_or(false)
    }
}

#[account]
pub struct PaymentRecord {
    pub payment_id: [u8; 32],
    pub payer: Pubkey,
    pub creator: Pubkey,
    pub amount: u64,
    pub payment_token: Pubkey,
    pub timestamp: i64,
    pub bump: u8,
}

impl PaymentRecord {
    pub const LEN: usize = 8 + 32 + 32 + 32 + 8 + 32 + 8 + 1;
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum SubscriptionStatus {
    Active,
    Cancelled,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum SplitStrategy {
    Strategy100_0,
    Strategy96_4,
    Strategy95_5,
    Strategy94_6,
    Strategy93_7,
    Strategy90_10,
}

impl SplitStrategy {
    pub fn get_platform_bps(&self) -> u16 {
        match self {
            SplitStrategy::Strategy100_0 => 0,
            SplitStrategy::Strategy96_4 => 400,
            SplitStrategy::Strategy95_5 => 500,
            SplitStrategy::Strategy94_6 => 600,
            SplitStrategy::Strategy93_7 => 700,
            SplitStrategy::Strategy90_10 => 1000,
        }
    }

    pub fn get_creator_bps(&self) -> u16 {
        10000 - self.get_platform_bps()
    }

    pub fn calculate_amounts(&self, total: u64) -> (u64, u64) {
        let platform_bps = self.get_platform_bps() as u128;
        let platform_amount =
            ((total as u128).checked_mul(platform_bps).unwrap_or(0) / 10000u128) as u64;
        let creator_amount = total.checked_sub(platform_amount).unwrap_or(0);
        (creator_amount, platform_amount)
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq)]
pub struct AutoRenewalConsent {
    pub enabled: bool,
    pub consent_timestamp: i64,
    pub max_allowance: u64,
    pub token_mint: Pubkey,
    pub product_id: u64,
    pub grace_period_end: i64,
}

impl Default for AutoRenewalConsent {
    fn default() -> Self {
        Self {
            enabled: false,
            consent_timestamp: 0,
            max_allowance: 0,
            token_mint: Pubkey::default(),
            product_id: 0,
            grace_period_end: 0,
        }
    }
}

pub fn is_valid_status_transition(from: SubscriptionStatus, to: SubscriptionStatus) -> bool {
    matches!(
        (from, to),
        (SubscriptionStatus::Active, SubscriptionStatus::Cancelled)
    )
}
