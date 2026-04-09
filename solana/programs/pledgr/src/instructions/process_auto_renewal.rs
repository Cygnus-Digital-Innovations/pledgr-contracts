use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

#[derive(Accounts)]
#[instruction(subscription_id: [u8; 32])]
pub struct ProcessAutoRenewal<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = !config.paused @ PledgrError::ProgramPaused
    )]
    pub config: Box<Account<'info, PledgrConfig>>,

    #[account(
        mut,
        seeds = [SUBSCRIPTION_SEED, subscription.subscriber.as_ref(), &subscription_id],
        bump = subscription.bump,
        constraint = subscription.status == SubscriptionStatus::Active @ PledgrError::SubscriptionNotActive
    )]
    pub subscription: Box<Account<'info, Subscription>>,

    #[account(
        mut,
        constraint = subscriber_token_account.owner == subscription.subscriber @ PledgrError::Unauthorized,
        constraint = subscriber_token_account.mint == subscription.payment_token_mint @ PledgrError::InvalidToken,
        constraint = subscriber_token_account.amount >= subscription.price @ PledgrError::InsufficientBalance,
        constraint = subscriber_token_account.delegate.is_some() @ PledgrError::AutoRenewalNotEnabled,
        constraint = subscriber_token_account.delegate.unwrap() == config.key() @ PledgrError::Unauthorized,
        constraint = subscriber_token_account.delegated_amount >= subscription.price @ PledgrError::ExceedsMaxAllowance
    )]
    pub subscriber_token_account: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        constraint = creator_token_account.owner == subscription.creator @ PledgrError::Unauthorized,
        constraint = creator_token_account.mint == subscription.payment_token_mint @ PledgrError::InvalidToken,
        constraint = creator_token_account.key() == anchor_spl::associated_token::get_associated_token_address(&subscription.creator, &subscription.payment_token_mint) @ PledgrError::InvalidToken
    )]
    pub creator_token_account: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        constraint = co_owner_one_token_account.owner == config.co_owner_one @ PledgrError::Unauthorized,
        constraint = co_owner_one_token_account.mint == subscription.payment_token_mint @ PledgrError::InvalidToken,
        constraint = co_owner_one_token_account.key() == anchor_spl::associated_token::get_associated_token_address(&config.co_owner_one, &subscription.payment_token_mint) @ PledgrError::InvalidToken
    )]
    pub co_owner_one_token_account: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        constraint = co_owner_two_token_account.owner == config.co_owner_two @ PledgrError::Unauthorized,
        constraint = co_owner_two_token_account.mint == subscription.payment_token_mint @ PledgrError::InvalidToken,
        constraint = co_owner_two_token_account.key() == anchor_spl::associated_token::get_associated_token_address(&config.co_owner_two, &subscription.payment_token_mint) @ PledgrError::InvalidToken
    )]
    pub co_owner_two_token_account: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        constraint = co_owner_three_token_account.owner == config.co_owner_three @ PledgrError::Unauthorized,
        constraint = co_owner_three_token_account.mint == subscription.payment_token_mint @ PledgrError::InvalidToken,
        constraint = co_owner_three_token_account.key() == anchor_spl::associated_token::get_associated_token_address(&config.co_owner_three, &subscription.payment_token_mint) @ PledgrError::InvalidToken
    )]
    pub co_owner_three_token_account: Box<Account<'info, TokenAccount>>,

    pub executor: Option<Signer<'info>>,

    #[account(
        mut,
        constraint = bounty_source.owner == config.key() @ PledgrError::Unauthorized,
        constraint = bounty_source.mint == subscription.payment_token_mint @ PledgrError::InvalidToken
    )]
    pub bounty_source: Option<Account<'info, TokenAccount>>,

    #[account(
        mut,
        constraint = executor_token_account.mint == subscription.payment_token_mint @ PledgrError::InvalidToken,
        constraint = executor_token_account.owner == executor.as_ref().unwrap().key() @ PledgrError::Unauthorized
    )]
    pub executor_token_account: Option<Account<'info, TokenAccount>>,

    pub token_program: Program<'info, Token>,
}

pub fn handler(ctx: Context<ProcessAutoRenewal>, _subscription_id: [u8; 32]) -> Result<()> {
    let config = &ctx.accounts.config;

    let subscription = &ctx.accounts.subscription;
    let clock = Clock::get()?;

    require!(
        subscription.auto_renewal_consent.enabled,
        PledgrError::AutoRenewalNotEnabled
    );
    require!(
        subscription.price <= subscription.auto_renewal_consent.max_allowance,
        PledgrError::ExceedsMaxAllowance
    );

    let grace_period_end = subscription
        .next_due
        .saturating_add(subscription.grace_secs as i64);
    if clock.unix_timestamp > grace_period_end {
        let sub = &mut ctx.accounts.subscription;
        sub.status = SubscriptionStatus::Cancelled;
        return Ok(());
    }

    require!(
        clock.unix_timestamp >= subscription.next_due,
        PledgrError::PaymentNotDue
    );
    require!(
        !subscription.is_already_charged_this_period(clock.unix_timestamp),
        PledgrError::AlreadyChargedThisPeriod
    );
    let token_mint = ctx.accounts.subscriber_token_account.mint;
    require!(
        config.is_token_supported(&token_mint),
        PledgrError::InvalidToken
    );

    let amount = subscription.price;
    let (creator_amount, platform_amount) = subscription.split_strategy.calculate_amounts(amount);

    let processor_seeds = &[PROCESSOR_SEED, &[ctx.accounts.config.bump]];
    let signer_seeds = &[&processor_seeds[..]];

    if creator_amount > 0 {
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.subscriber_token_account.to_account_info(),
                    to: ctx.accounts.creator_token_account.to_account_info(),
                    authority: ctx.accounts.config.to_account_info(),
                },
                signer_seeds,
            ),
            creator_amount,
        )?;
    }

    if platform_amount > 0 {
        let (wallet_amount, maintenance_amount, referral_amount) =
            config.calculate_co_owner_split(platform_amount);

        if wallet_amount > 0 {
            token::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: ctx.accounts.subscriber_token_account.to_account_info(),
                        to: ctx.accounts.co_owner_one_token_account.to_account_info(),
                        authority: ctx.accounts.config.to_account_info(),
                    },
                    signer_seeds,
                ),
                wallet_amount,
            )?;
        }
        if maintenance_amount > 0 {
            token::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: ctx.accounts.subscriber_token_account.to_account_info(),
                        to: ctx.accounts.co_owner_two_token_account.to_account_info(),
                        authority: ctx.accounts.config.to_account_info(),
                    },
                    signer_seeds,
                ),
                maintenance_amount,
            )?;
        }
        if referral_amount > 0 {
            token::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: ctx.accounts.subscriber_token_account.to_account_info(),
                        to: ctx.accounts.co_owner_three_token_account.to_account_info(),
                        authority: ctx.accounts.config.to_account_info(),
                    },
                    signer_seeds,
                ),
                referral_amount,
            )?;
        }
    }

    if config.bounty_enabled {
        if let (Some(bounty_src), Some(executor_ata)) = (
            &ctx.accounts.bounty_source,
            &ctx.accounts.executor_token_account,
        ) {
            let (_, _, co_owner_three_share) = config.calculate_co_owner_split(platform_amount);
            let bounty = std::cmp::min(config.bounty_per_renewal, config.max_bounty_per_tx);
            let bounty = std::cmp::min(bounty, co_owner_three_share);
            if bounty > 0 && bounty_src.amount >= bounty {
                token::transfer(
                    CpiContext::new_with_signer(
                        ctx.accounts.token_program.to_account_info(),
                        Transfer {
                            from: bounty_src.to_account_info(),
                            to: executor_ata.to_account_info(),
                            authority: ctx.accounts.config.to_account_info(),
                        },
                        signer_seeds,
                    ),
                    bounty,
                )?;
                emit!(BountyPaid {
                    executor: executor_ata.owner,
                    token_mint: subscription.payment_token_mint,
                    amount: bounty,
                    timestamp: clock.unix_timestamp,
                });
            } else {
                emit!(BountyPaymentFailed {
                    executor: executor_ata.owner,
                    token_mint: subscription.payment_token_mint,
                    amount: bounty,
                    timestamp: clock.unix_timestamp,
                });
            }
        }
    }

    let subscription = &mut ctx.accounts.subscription;
    subscription.last_charged = clock.unix_timestamp;
    subscription.total_paid = subscription
        .total_paid
        .checked_add(amount)
        .ok_or(PledgrError::ArithmeticOverflow)?;
    subscription.payment_count = subscription
        .payment_count
        .checked_add(1)
        .ok_or(PledgrError::ArithmeticOverflow)?;
    if subscription.period_secs > 0 {
        subscription.next_due = clock
            .unix_timestamp
            .checked_add(subscription.period_secs as i64)
            .ok_or(PledgrError::ArithmeticOverflow)?;
    }
    if subscription.auto_renewal_consent.enabled {
        subscription.auto_renewal_consent.consent_timestamp = clock.unix_timestamp;
    }

    let config = &mut ctx.accounts.config;
    config.total_processed = config
        .total_processed
        .checked_add(amount)
        .ok_or(PledgrError::ArithmeticOverflow)?;

    emit!(AutoRenewalProcessed {
        subscription_id: _subscription_id,
        subscriber: subscription.subscriber,
        amount,
        success: true,
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}

#[event]
pub struct AutoRenewalProcessed {
    pub subscription_id: [u8; 32],
    pub subscriber: Pubkey,
    pub amount: u64,
    pub success: bool,
    pub timestamp: i64,
}

#[event]
pub struct BountyPaid {
    pub executor: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
    pub timestamp: i64,
}

#[event]
pub struct BountyPaymentFailed {
    pub executor: Pubkey,
    pub token_mint: Pubkey,
    pub amount: u64,
    pub timestamp: i64,
}
