use alloy_core::domain::env::Env;
use alloy_core::domain::ports;
use alloy_core::infra::System;

pub struct Ctx {
    pub env: Env,
    pub system: System,
}

impl ports::Ctx for Ctx {
    fn env(&self) -> &alloy_core::domain::env::Env {
        &self.env
    }

    fn env_mut(&mut self) -> &mut alloy_core::domain::env::Env {
        &mut self.env
    }

    fn nix(&self) -> &dyn ports::Nix {
        &self.system
    }

    fn fs(&self) -> &dyn ports::Fs {
        &self.system
    }

    fn git(&self) -> &dyn ports::Git {
        &self.system
    }

    fn age(&self) -> &dyn ports::Age {
        &self.system
    }

    fn gen_runner(&self) -> &dyn ports::GenRunner {
        &self.system
    }

    fn qemu_runner(&self) -> &dyn ports::QemuRunner {
        &self.system
    }
}
