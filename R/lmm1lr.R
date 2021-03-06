#-------------------------
# Main function `lmm1`
#-------------------------

#' LMM with a single random effect and residual random effect.
#'
#' @export
lmm1lr <- function(formula, data, zmat, REML = TRUE, 
  store_mat = FALSE, start = 0.5,
  verbose = 0)
{ 
  ### call
  mc <- match.call()
  env <- parent.frame(1)
  
  ### args
  stopifnot(!missing(zmat))

  ### ids
  if(is.null(rownames(data))) {
    ids <- as.character(1:nrow(data))
  } else {
    ids <- rownames(data)
  }
  stopifnot(!any(duplicated(ids)))
      
  ### extract model/response matrices
  if(verbose) {
    cat(" - extract model/response matrices\n")
  }
  X <- model.matrix(formula, data)
  y <- model.extract(model.frame(formula, data), "response")
  
  nobs_data <- nrow(data)
  nobs_model <- nrow(X)

  obs_model <- which(rownames(X) %in% ids)
  obs_omit <- which(!(rownames(X) %in% ids))

  ids_model <- ids[obs_model]
  
  ### check
  if(verbose) {
    cat(" - check\n")
  }
  if(nrow(zmat) != nobs_data) {
    stop("zmat dimension")
  } else {
    ids_zmat <- rownames(zmat)
    
    skip <- (nobs_model == length(ids_zmat))
    if(skip) {
      skip <- ifelse(all.equal(ids_model, ids_zmat), TRUE, FALSE)
    }
    
    if(!skip) {
      if(verbose > 1) {
        cat(" - checking ids/rownames\n")
      }    
      if(!is.null(rownames(zmat))) {
        stopifnot(all(ids_zmat %in% ids))
            
        ind <- sapply(ids_model, function(x) which(x == ids_zmat))
        zmat <- zmat[ind, ]
      } else {
        zmat <- zmat[obs_model, ]
      }
    }
  }
  
  ### optimize
  if(verbose) {
    cat(" - optimize\n")
  }
  # v1: optimize
  out <- optimize(lmm1_compute_lowrank_ll, c(0, 1), 
    y = y, X = X, Z = zmat, REML = REML, verbose = verbose,
    maximum = TRUE)
  r2 <- out$maximum
  ll <- out$objective
  convergence <- NA
  
  #stopifnot(require(optimx))
  #out <- optimx::optimx(start_r2, lmm1_compute_lowrank_ll, 
  #  lower = 0, upper = 1, method = "Nelder-Mead",
  #  control = list(maximize = TRUE),
  #  # par. passed to `lmm1_compute_lowrank_l`
  #  y = y, X = X, Z = zmat, REML = REML, verbose = verbose)
  
  # v3: optim + starting values
  #out <- optim(start, lmm1_compute_lowrank_ll,
  #  lower = 0, upper = 1, 
  #  method = "Brent", 
  #  control = list(fnscale = -1, trace = 1), # maximize
  #  y = y, X = X, Z = zmat, REML = REML, verbose = verbose)
  #r2 <- out$par
  #ll <- out$value
  #convergence <- out$convergence

  ### fixed effects estimates
  est <- lmm1lr_effects(gamma = r2, y = y, X = X, Z = zmat, REML = REML)
  
  coef <- data.frame(estimate = est$b, se = sqrt(diag(est$bcov)))
  coef <- within(coef, z <- estimate / se)
  
  ### ranef. effect estimates
  gamma <- r2
  s2 <- est$s2
  comp <- s2 * c(gamma, 1 - gamma)
  
  ### return
  mod <- list(nobs_data = nobs_data, nobs_model = nobs_model,
    obs_model = obs_model, obs_omit = obs_omit,
    gamma = gamma, s2 = s2, comp = comp,
    est = est, coef = coef,
    REML = REML, store_mat = store_mat)
  
  if(store_mat) {
    mod <- c(mod, list(y = y, X = X, Z = zmat))
  }
  
  mod$lmm <- list(r2 = r2, ll = ll, convergence = convergence, REML = REML)
  
  return(mod)
}

#-------------------------------
# Fixed effects: etimates & cov
#-------------------------------

lmm1lr_effects <- function(model, gamma, y, X, Z, s2, REML = TRUE)
{
  ### args 
  missing_model <- missing(model)
  missing_s2 <- missing(s2)
  
  if(missing_model) {
    n <- length(y)
    k <- ncol(X)
    nk <- ifelse(REML, n - k, n)
    
    if(missing_s2) {
      # copmute effect sizes (`b`) with scaled V = gamma ZZ' + (1-gamma) I
      comp <- c(gamma, 1 - gamma)
  
      XV <- crossprod_inverse_woodburry(comp, Z, X) # crossprod(X, Sigma_inv)
      XVX <- XV %*% X
  
      b <- as.numeric(solve(XVX) %*% (XV %*% y))
  
      # comptes SE taking into account `s2`: V = s2 (gamma ZZ' + (1-gamma) I)
      r <- as.numeric(y - X %*% b)
      yPy <- crossprod_inverse_woodburry(comp, Z, r) %*% r # crossprod(r, Sigma_inv) %*% r
      s2 <- as.numeric(yPy / nk)
  
      comp <- s2 * c(gamma, 1 - gamma)
  
      XV <- crossprod_inverse_woodburry(comp, Z, X) # crossprod(X, Sigma_inv)
      XVX <- XV %*% X
      bcov <- solve(XVX)
    } else {
      comp <- s2 * c(gamma, 1 - gamma)
      XV <- crossprod_inverse_woodburry(comp, Z, X) # crossprod(X, Sigma_inv)
      XVX <- XV %*% X
      XVX_inv <- solve(XVX)
      
      b <- as.numeric(XVX_inv %*% (XV %*% y))
      bcov <- XVX_inv
    }
  } else {
    stop("not implemented")
  }
  
  ### return
  out <- list(s2 = s2, b = b, bcov = bcov)
}

#-------------------------------
# Fixed effects: etimates & cov
#-------------------------------

lmm1lr_predictors <- function(model, pred, verbose = 0)
{
  ### args 
  stopifnot(model$store_mat)
  
  y <- model$y
  X <- model$X
  Z <- model$Z
  
  comp <- model$s2 * c(model$gamma, 1 - model$gamma)
  
  M <- ncol(pred)
  out <- lapply(seq(1, ncol(pred)), function(i) {
    if(verbose) {
      cat(" -", i, "/", M, "predictor\n")
    }
    if(length(model$obs_omit) == 0) {
      Xi <- cbind(X, pred[, i])
      
      XV <- crossprod_inverse_woodburry(comp, Z, Xi) # crossprod(X, Sigma_inv)
      XVX <- XV %*% Xi
      XVX_inv <- solve(XVX)
      
      b <- as.numeric(XVX_inv %*% (XV %*% y))
      bcov <- XVX_inv
    } else {
      stop("not implemented")
    }
    
    k <- ncol(Xi)
    out <- list(b = b[k], se = sqrt(bcov[k, k]))
  })
  
  tab <- bind_rows(out)
  tab <- within(tab, {
    z <- b/se
    p <- pchisq(z*z, df = 1, lower = FALSE)
  })
    
  ### return
  return(tab)
}

#-------------------------
# LogLik computation 
#-------------------------

lmm1_compute_lowrank_ll <- function(gamma, y, X, Z, REML = TRUE, verbose = 0)
{
  if(verbose > 1) {
    cat(" - lmm1_compute_lowrank_ll\n")
  }

  n <- length(y)
  k <- ncol(X)
  
  nk <- ifelse(REML, n - k, n)
  
  comp <- c(gamma, 1 - gamma)
  
  Sigma_det_log <- log_det_decomp(comp, Z) 
  
  XV <- crossprod_inverse_woodburry(comp, Z, X) # crossprod(X, Sigma_inv)
  XVX <- XV %*% X
  
  b <- solve(XVX) %*% (XV %*% y) 
  
  r <- as.numeric(y - X %*% b)
  yPy <- crossprod_inverse_woodburry(comp, Z, r) %*% r # crossprod(r, Sigma_inv) %*% r
  s2 <- yPy / nk

  ll <- -0.5*nk*(log(2*pi*s2) + 1) - 0.5*Sigma_det_log
  if(REML) {
    log_det_XVX <- determinant(XVX, log = TRUE)
    #log_det_XX <- determinant(crossprod(X), log = TRUE)
    
    ll <- ll - 0.5*as.numeric(log_det_XVX$modulus)
  }
  
  if(verbose > 1) {
    cat("  -- gamma", gamma, "; ll", ll, "\n")
  }
    
  return(as.numeric(ll))
}

lmm1_compute_naive_ll <- function(gamma, y, X, G, REML = TRUE)
{
  n <- length(y)
  k <- ncol(X)
  
  nk <- ifelse(REML, n - k, n)
  
  Sigma <- gamma*G + (1 - gamma)*diag(n)
  Sigma_inv <- solve(Sigma)
  Sigma_det_log <- as.numeric(determinant(Sigma, log = TRUE)$modulus)
  
  XV <- crossprod(X, Sigma_inv)
  XVX <- XV %*% X
  b <- solve(XVX) %*% (XV %*% y) 
  
  r <- as.numeric(y - X %*% b)
  yPy <- crossprod(r, Sigma_inv) %*% r
  s2 <- yPy / nk

  ll <- -0.5*nk*(log(2*pi*s2) + 1) - 0.5*Sigma_det_log
  if(REML) {
    log_det_XVX <- determinant(XVX, log = TRUE)
    #log_det_XX <- determinant(crossprod(X), log = TRUE)
    
    ll <- ll - 0.5*as.numeric(log_det_XVX$modulus)
  }
  
  return(ll)
}

#-------------------------
# Support functions of linear algebra 
#-------------------------

### efficient inverse matrix calc.
inverse_woodburry <- function(comp, Z)
{ 
  # (1) Formula from https://en.wikipedia.org/wiki/Woodbury_matrix_identity
  # (A + UCV)- = A- - A- U (C- + VA-U)-VA-
  # (D + ZHZ')- = D- - D-Z (H- + Z'D-Z)-Z'D- = D- - D-ZL-Z'D-
  # where D = diag(comp1), H = diag(comp2), L = (H- + Z'D-Z)
  n <- nrow(Z)
  k <- ncol(Z)
  
  Li <- solve(diag(k) / comp[1] + crossprod(Z) / comp[2])
  diag(n) / comp[2] - Z %*% tcrossprod(Li, Z) / (comp[2] * comp[2])
}

### efficient calc. of X'V
crossprod_inverse_woodburry <- function(comp, Z, X)
{ 
  n <- nrow(Z)
  k <- ncol(Z)
  
  Li <- solve(diag(k) / comp[1] + crossprod(Z) / comp[2])
  t(X) / comp[2] - crossprod(X, Z) %*% tcrossprod(Li, Z) / (comp[2] * comp[2])
}

### efficient det calc.
log_det_decomp <- function(comp, Z)
{ 
  # (1) General formula from https://en.wikipedia.org/wiki/Matrix_determinant_lemma
  # |A + UCV| = |L| |C| |A|
  # where L = C- + VA-U
  # (2) For our specific case:
  # |D + ZHZ'| = |L| |H| |D|
  # D = diag(comp1), H = diag(comp2), L = (H- + Z'D-Z)
  n <- nrow(Z)
  k <- ncol(Z)
  
  L <- diag(k) / comp[1] + crossprod(Z) / comp[2]
  log_det_L <- determinant(L, log = TRUE)
  
  as.numeric(log_det_L$modulus) + n*log(comp[2]) + k*log(comp[1])
}

### efficient calc. of X'V
trace_inverse_woodburry <- function(comp, Z, batch = 500, verbose = 0)
{ 
  n <- nrow(Z)
  k <- ncol(Z)
  
  beg <- seq(1, n, by = batch) 
  end <- c(beg[-1] - 1, n)  
  nb <- length(beg)
  
  d <- lapply(seq(1, nb), function(b) {
    if(verbose) {
      cat(" -", b, "/", nb, "\n")
    }
    
    rows <- seq(beg[b], end[b])
    E <- sapply(rows, function(r) {
      e <- rep(0, n)
      e[r] <- 1
      e
    })
        
    R <- crossprod_inverse_woodburry(comp, Z, E)
    
    R[, rows, drop = FALSE] %>% diag
  })
  d <- unlist(d)
  sum(d)
}









