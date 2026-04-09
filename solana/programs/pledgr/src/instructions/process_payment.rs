use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::associated_token::{AssociatedToken, Create};
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

#[derive(Accounts)]
#[instruction(amount: u64, payment_id: [u8; 32], split_strategy: Option<SplitStrategy>, fees: u64)]
pub struct ProcessPayment<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = !config.paused @ PledgrError::ProgramPaused
    )]
    pub config: Box<Account<'info, PledgrConfig>>,

    #[account(
        init,
        payer = payer,
        space = PaymentRecord::LEN,
        seeds = [PAYMENT_RECORD_SEED, payer.key().as_ref(), payment_id.as_ref()],
        bump
    )]
    pub payment_record: Box<Account<'info, PaymentRecord>>,

    pub payment_token_mint: Account<'info, Mint>,

    #[account(
        mut,
        constraint = payer_token_account.owner == payer.key() @ PledgrError::Unauthorized,
        constraint = payer_token_account.mint == payment_token_mint.key() @ PledgrError::InvalidToken,
        constraint = payer_token_account.amount >= amount @ PledgrError::InsufficientBalance
    )]
    pub payer_token_account: Box<Account<'info, TokenAccount>>,

    /// CHECK: Creator receiving payment
    pub creator: UncheckedAccount<'info>,

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
    pub payer: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handler(
    ctx: Context<ProcessPayment>,
    amount: u64,
    payment_id: [u8; 32],
    split_strategy: Option<SplitStrategy>,
    fees: u64,
) -> Result<()> {
    let clock = Clock::get()?;

    require!(amount > 0, PledgrError::InvalidAmount);
    require!(
        ctx.accounts.creator.key() != ctx.accounts.config.co_owner_one
            && ctx.accounts.creator.key() != ctx.accounts.config.co_owner_two
            && ctx.accounts.creator.key() != ctx.accounts.config.co_owner_three,
        PledgrError::CreatorCannotBePlatform
    );
    require!(
        ctx.accounts
            .config
            .is_token_supported(&ctx.accounts.payment_token_mint.key()),
        PledgrError::TokenNotSupported
    );

    let strategy = split_strategy.unwrap_or(SplitStrategy::Strategy95_5);
    let (creator_amount, platform_amount) = strategy.calculate_amounts(amount);

    ensure_ata_and_transfer(
        &ctx.accounts.creator,
        &ctx.accounts.creator_token_account,
        &ctx.accounts.payment_token_mint.to_account_info(),
        &ctx.accounts.payer_token_account.to_account_info(),
        &ctx.accounts.payer,
        &ctx.accounts.token_program,
        &ctx.accounts.associated_token_program,
        &ctx.accounts.system_program,
        creator_amount,
    )?;

    if platform_amount > 0 {
        let (wallet_amount, maintenance_amount, referral_amount) = ctx
            .accounts
            .config
            .calculate_co_owner_split(platform_amount);

        if wallet_amount > 0 {
            ensure_ata_and_transfer(
                &ctx.accounts.co_owner_one,
                &ctx.accounts.co_owner_one_token_account,
                &ctx.accounts.payment_token_mint.to_account_info(),
                &ctx.accounts.payer_token_account.to_account_info(),
                &ctx.accounts.payer,
                &ctx.accounts.token_program,
                &ctx.accounts.associated_token_program,
                &ctx.accounts.system_program,
                wallet_amount,
            )?;
        }
        if maintenance_amount > 0 {
            ensure_ata_and_transfer(
                &ctx.accounts.co_owner_two,
                &ctx.accounts.co_owner_two_token_account,
                &ctx.accounts.payment_token_mint.to_account_info(),
                &ctx.accounts.payer_token_account.to_account_info(),
                &ctx.accounts.payer,
                &ctx.accounts.token_program,
                &ctx.accounts.associated_token_program,
                &ctx.accounts.system_program,
                maintenance_amount,
            )?;
        }
        if referral_amount > 0 {
            ensure_ata_and_transfer(
                &ctx.accounts.co_owner_three,
                &ctx.accounts.co_owner_three_token_account,
                &ctx.accounts.payment_token_mint.to_account_info(),
                &ctx.accounts.payer_token_account.to_account_info(),
                &ctx.accounts.payer,
                &ctx.accounts.token_program,
                &ctx.accounts.associated_token_program,
                &ctx.accounts.system_program,
                referral_amount,
            )?;
        }
    }

    if fees > 0 {
        ensure_ata_and_transfer(
            &ctx.accounts.co_owner_three,
            &ctx.accounts.co_owner_three_token_account,
            &ctx.accounts.payment_token_mint.to_account_info(),
            &ctx.accounts.payer_token_account.to_account_info(),
            &ctx.accounts.payer,
            &ctx.accounts.token_program,
            &ctx.accounts.associated_token_program,
            &ctx.accounts.system_program,
            fees,
        )?;
    }

    let config = &mut ctx.accounts.config;
    config.total_processed = config
        .total_processed
        .checked_add(amount)
        .and_then(|v| v.checked_add(fees))
        .ok_or(PledgrError::ArithmeticOverflow)?;

    let payment_record = &mut ctx.accounts.payment_record;
    payment_record.payment_id = payment_id;
    payment_record.payer = ctx.accounts.payer.key();
    payment_record.creator = ctx.accounts.creator.key();
    payment_record.amount = amount;
    payment_record.payment_token = ctx.accounts.payment_token_mint.key();
    payment_record.timestamp = clock.unix_timestamp;
    payment_record.bump = ctx.bumps.payment_record;

    emit!(PaymentProcessed {
        payment_id,
        payer: ctx.accounts.payer.key(),
        creator: ctx.accounts.creator.key(),
        payment_token: ctx.accounts.payment_token_mint.key(),
        amount,
        creator_amount,
        platform_amount,
        fees,
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}

pub fn ensure_ata_and_transfer<'info>(
    wallet: &AccountInfo<'info>,
    token_account: &AccountInfo<'info>,
    mint: &AccountInfo<'info>,
    from: &AccountInfo<'info>,
    payer: &Signer<'info>,
    token_program: &Program<'info, Token>,
    ata_program: &Program<'info, AssociatedToken>,
    system_program: &Program<'info, System>,
    amount: u64,
) -> Result<()> {
    let expected_ata =
        anchor_spl::associated_token::get_associated_token_address(&wallet.key(), &mint.key());
    require!(
        token_account.key() == expected_ata,
        PledgrError::InvalidToken
    );

    let is_initialized =
        *token_account.owner == token_program.key() && token_account.data_len() >= 165;

    if !is_initialized {
        anchor_spl::associated_token::create(CpiContext::new(
            ata_program.to_account_info(),
            Create {
                payer: payer.to_account_info(),
                associated_token: token_account.clone(),
                authority: wallet.clone(),
                mint: mint.clone(),
                system_program: system_program.to_account_info(),
                token_program: token_program.to_account_info(),
            },
        ))?;
    }

    token::transfer(
        CpiContext::new(
            token_program.to_account_info(),
            Transfer {
                from: from.clone(),
                to: token_account.clone(),
                authority: payer.to_account_info(),
            },
        ),
        amount,
    )?;

    Ok(())
}

#[event]
pub struct PaymentProcessed {
    pub payment_id: [u8; 32],
    pub payer: Pubkey,
    pub creator: Pubkey,
    pub payment_token: Pubkey,
    pub amount: u64,
    pub creator_amount: u64,
    pub platform_amount: u64,
    pub fees: u64,
    pub timestamp: i64,
}
