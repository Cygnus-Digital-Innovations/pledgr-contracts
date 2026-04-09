use super::process_payment::ensure_ata_and_transfer;
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{Mint, Token, TokenAccount};

#[derive(Accounts)]
#[instruction(params: UpgradeSubscriptionParams)]
pub struct UpgradeSubscription<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = !config.paused @ PledgrError::ProgramPaused
    )]
    pub config: Box<Account<'info, PledgrConfig>>,

    #[account(
        mut,
        seeds = [SUBSCRIPTION_SEED, old_subscription.subscriber.as_ref(), &old_subscription.subscription_id],
        bump = old_subscription.bump,
        constraint = old_subscription.status == SubscriptionStatus::Active @ PledgrError::SubscriptionNotActive,
        constraint = old_subscription.subscriber == subscriber.key() @ PledgrError::Unauthorized
    )]
    pub old_subscription: Account<'info, Subscription>,

    #[account(
        init,
        payer = subscriber,
        space = Subscription::LEN,
        seeds = [SUBSCRIPTION_SEED, subscriber.key().as_ref(), &params.new_subscription_id],
        bump
    )]
    pub new_subscription: Box<Account<'info, Subscription>>,

    pub payment_token_mint: Account<'info, Mint>,

    #[account(
        mut,
        constraint = subscriber_token_account.owner == subscriber.key() @ PledgrError::Unauthorized,
        constraint = subscriber_token_account.mint == payment_token_mint.key() @ PledgrError::InvalidToken
    )]
    pub subscriber_token_account: Box<Account<'info, TokenAccount>>,

    /// CHECK: Creator wallet - must match old subscription
    pub creator: AccountInfo<'info>,

    /// CHECK: Creator's ATA
    #[account(mut)]
    pub creator_token_account: UncheckedAccount<'info>,

    /// CHECK: Validated against config
    #[account(constraint = co_owner_one.key() == config.co_owner_one @ PledgrError::Unauthorized)]
    pub co_owner_one: UncheckedAccount<'info>,

    /// CHECK: Platform ATA
    #[account(mut)]
    pub co_owner_one_token_account: UncheckedAccount<'info>,

    /// CHECK: Validated against config
    #[account(constraint = co_owner_two.key() == config.co_owner_two @ PledgrError::Unauthorized)]
    pub co_owner_two: UncheckedAccount<'info>,

    /// CHECK: Maintenance ATA
    #[account(mut)]
    pub co_owner_two_token_account: UncheckedAccount<'info>,

    /// CHECK: Validated against config
    #[account(constraint = co_owner_three.key() == config.co_owner_three @ PledgrError::Unauthorized)]
    pub co_owner_three: UncheckedAccount<'info>,

    /// CHECK: Referral ATA
    #[account(mut)]
    pub co_owner_three_token_account: UncheckedAccount<'info>,

    #[account(mut)]
    pub subscriber: Signer<'info>,

    pub associated_token_program: Program<'info, AssociatedToken>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct UpgradeSubscriptionParams {
    pub old_subscription_id: [u8; 32],
    pub new_subscription_id: [u8; 32],
    pub new_price: u64,
    pub new_split_strategy: SplitStrategy,
    pub new_period_secs: u32,
    pub prorated_amount: u64,
    pub max_allowance: u64,
    pub fees: u64,
}

pub fn handler(ctx: Context<UpgradeSubscription>, params: UpgradeSubscriptionParams) -> Result<()> {
    let clock = Clock::get()?;
    let config = &ctx.accounts.config;
    let old_subscription = &mut ctx.accounts.old_subscription;

    require!(
        params.old_subscription_id == old_subscription.subscription_id,
        PledgrError::Unauthorized
    );

    let token_mint = ctx.accounts.subscriber_token_account.mint;
    require!(
        config.is_token_supported(&token_mint),
        PledgrError::InvalidToken
    );
    require!(
        token_mint == old_subscription.payment_token_mint,
        PledgrError::InvalidToken
    );
    require!(
        ctx.accounts.creator.key() == old_subscription.creator,
        PledgrError::Unauthorized
    );
    require!(
        ctx.accounts.creator.key() != config.co_owner_one
            && ctx.accounts.creator.key() != config.co_owner_two
            && ctx.accounts.creator.key() != config.co_owner_three,
        PledgrError::CreatorCannotBePlatform
    );
    require!(
        params.new_price >= MIN_SUBSCRIPTION_PRICE,
        PledgrError::PriceTooLow
    );
    require!(params.new_period_secs > 0, PledgrError::InvalidAmount);
    require!(
        ctx.accounts.subscriber.key() != ctx.accounts.creator.key(),
        PledgrError::SelfSubscriptionNotAllowed
    );

    let old_price = old_subscription.price;
    require!(params.new_price > old_price, PledgrError::InvalidAmount);

    let price_diff = params
        .new_price
        .checked_sub(old_price)
        .ok_or(PledgrError::ArithmeticOverflow)?;

    if params.prorated_amount > 0 {
        require!(
            params.prorated_amount >= price_diff,
            PledgrError::InsufficientBalance
        );
        let total_required = params
            .prorated_amount
            .checked_add(params.fees)
            .ok_or(PledgrError::ArithmeticOverflow)?;
        require!(
            ctx.accounts.subscriber_token_account.amount >= total_required,
            PledgrError::InsufficientBalance
        );
    } else if params.fees > 0 {
        require!(
            ctx.accounts.subscriber_token_account.amount >= params.fees,
            PledgrError::InsufficientBalance
        );
    }

    old_subscription.status = SubscriptionStatus::Cancelled;
    old_subscription.auto_renewal_consent.enabled = false;
    old_subscription.auto_renewal_consent.max_allowance = 0;

    let created_at = clock.unix_timestamp;
    let next_due = created_at
        .checked_add(params.new_period_secs as i64)
        .ok_or(PledgrError::ArithmeticOverflow)?;

    let new_subscription = &mut ctx.accounts.new_subscription;
    new_subscription.subscription_id = params.new_subscription_id;
    new_subscription.creator = ctx.accounts.creator.key();
    new_subscription.subscriber = ctx.accounts.subscriber.key();
    new_subscription.price = params.new_price;
    new_subscription.payment_token_mint = old_subscription.payment_token_mint;
    new_subscription.split_strategy = params.new_split_strategy;
    new_subscription.period_secs = params.new_period_secs;
    new_subscription.next_due = next_due;
    new_subscription.grace_secs = 604800;
    new_subscription.created_at = created_at;
    new_subscription.last_charged = created_at;
    new_subscription.status = SubscriptionStatus::Active;
    new_subscription.total_paid = 0;
    new_subscription.payment_count = 0;
    new_subscription.trial_end_date = None;
    new_subscription.bump = ctx.bumps.new_subscription;

    if params.prorated_amount > 0 {
        let (creator_amount, platform_amount) = params
            .new_split_strategy
            .calculate_amounts(params.prorated_amount);

        ensure_ata_and_transfer(
            &ctx.accounts.creator.to_account_info(),
            &ctx.accounts.creator_token_account.to_account_info(),
            &ctx.accounts.payment_token_mint.to_account_info(),
            &ctx.accounts.subscriber_token_account.to_account_info(),
            &ctx.accounts.subscriber,
            &ctx.accounts.token_program,
            &ctx.accounts.associated_token_program,
            &ctx.accounts.system_program,
            creator_amount,
        )?;

        if platform_amount > 0 {
            let (wallet_amount, maintenance_amount, referral_amount) =
                config.calculate_co_owner_split(platform_amount);

            if wallet_amount > 0 {
                ensure_ata_and_transfer(
                    &ctx.accounts.co_owner_one.to_account_info(),
                    &ctx.accounts.co_owner_one_token_account.to_account_info(),
                    &ctx.accounts.payment_token_mint.to_account_info(),
                    &ctx.accounts.subscriber_token_account.to_account_info(),
                    &ctx.accounts.subscriber,
                    &ctx.accounts.token_program,
                    &ctx.accounts.associated_token_program,
                    &ctx.accounts.system_program,
                    wallet_amount,
                )?;
            }
            if maintenance_amount > 0 {
                ensure_ata_and_transfer(
                    &ctx.accounts.co_owner_two.to_account_info(),
                    &ctx.accounts.co_owner_two_token_account.to_account_info(),
                    &ctx.accounts.payment_token_mint.to_account_info(),
                    &ctx.accounts.subscriber_token_account.to_account_info(),
                    &ctx.accounts.subscriber,
                    &ctx.accounts.token_program,
                    &ctx.accounts.associated_token_program,
                    &ctx.accounts.system_program,
                    maintenance_amount,
                )?;
            }
            if referral_amount > 0 {
                ensure_ata_and_transfer(
                    &ctx.accounts.co_owner_three.to_account_info(),
                    &ctx.accounts.co_owner_three_token_account.to_account_info(),
                    &ctx.accounts.payment_token_mint.to_account_info(),
                    &ctx.accounts.subscriber_token_account.to_account_info(),
                    &ctx.accounts.subscriber,
                    &ctx.accounts.token_program,
                    &ctx.accounts.associated_token_program,
                    &ctx.accounts.system_program,
                    referral_amount,
                )?;
            }
        }

        if params.fees > 0 {
            ensure_ata_and_transfer(
                &ctx.accounts.co_owner_three.to_account_info(),
                &ctx.accounts.co_owner_three_token_account.to_account_info(),
                &ctx.accounts.payment_token_mint.to_account_info(),
                &ctx.accounts.subscriber_token_account.to_account_info(),
                &ctx.accounts.subscriber,
                &ctx.accounts.token_program,
                &ctx.accounts.associated_token_program,
                &ctx.accounts.system_program,
                params.fees,
            )?;
        }

        new_subscription.total_paid = params.prorated_amount;
        new_subscription.payment_count = 1;
    }

    new_subscription.auto_renewal_consent = AutoRenewalConsent {
        enabled: true,
        consent_timestamp: created_at,
        max_allowance: params.max_allowance,
        token_mint: old_subscription.payment_token_mint,
        product_id: u64::from_le_bytes(params.new_subscription_id[0..8].try_into().unwrap()),
        grace_period_end: 0,
    };

    let config = &mut ctx.accounts.config;
    config.total_processed = config
        .total_processed
        .checked_add(params.prorated_amount)
        .and_then(|v| v.checked_add(params.fees))
        .ok_or(PledgrError::ArithmeticOverflow)?;
    config.total_subscriptions = config
        .total_subscriptions
        .checked_add(1)
        .ok_or(PledgrError::ArithmeticOverflow)?;

    emit!(SubscriptionUpgraded {
        old_subscription_id: params.old_subscription_id,
        new_subscription_id: params.new_subscription_id,
        subscriber: ctx.accounts.subscriber.key(),
        old_price,
        new_price: params.new_price,
        prorated_amount: params.prorated_amount,
        timestamp: created_at,
    });

    Ok(())
}

#[event]
pub struct SubscriptionUpgraded {
    pub old_subscription_id: [u8; 32],
    pub new_subscription_id: [u8; 32],
    pub subscriber: Pubkey,
    pub old_price: u64,
    pub new_price: u64,
    pub prorated_amount: u64,
    pub timestamp: i64,
}
