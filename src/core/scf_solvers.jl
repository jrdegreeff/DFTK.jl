# these provide fixed-point solvers that can be passed to scf()

# the fp_solver function must accept being called like fp_solver(f, x0, tol,
# maxiter), where f(x) is the fixed-point map. It must return an
# object supporting res.sol and res.converged

using NLsolve

# TODO max_iter could go to the solver generator function arguments

"""
Create a NLSolve-based SCF solver, by default using an Anderson-accelerated
fixed-point scheme, keeping `m` steps for Anderson acceleration. See the
NLSolve documentation for details about the other parameters and methods.
"""
function scf_nlsolve_solver(m=5, method=:anderson; kwargs...)
    function fp_solver(f, x0, tol, max_iter)
        res = nlsolve(x -> f(x) - x, x0; method=method, m=m, xtol=tol,
                      ftol=0.0, show_trace=true, iterations=max_iter, kwargs...)
        (fixpoint=res.zero, converged=converged(res))
    end
    fp_solver
end

"""
Create a damped SCF solver updating the density as
`x = β * x_new + (1 - β) * x`
"""
function scf_damping_solver(β=0.2)
    function fp_solver(f, x0, tol, max_iter)
        converged = false
        x = copy(x0)
        for i in 1:max_iter
            x_new = f(x)

            # TODO Print statements should not be here
            ndiff = norm(x_new - x)
            @printf "%4d %18.8g\n" i ndiff

            if 20 * ndiff < tol
                x = x_new
                converged = true
                break
            end

            x = @. β * x_new + (1 - β) * x
        end
        (fixpoint=x, converged=converged)
    end
    fp_solver
end

"""
Anderson-accelerated root-finding iteration for finding a
root of `f`, starting from `x0` and keeping a history of `m` steps.
Optionally `warming` specifies the number of non-accelerated steps to perform
for warming up the history.
"""
function anderson(f, x0, m::Int, max_iter::Int, tol::Real, warming=0)

    # Cheat support for multidimensional arrays
    if length(size(x0)) != 1
        x, conv= anderson(x -> vec(f(reshape(x, size(x0)...))), vec(x0), m, max_iter, tol, warming)
        return (fixpoint=reshape(x, size(x0)...), converged=conv)
    end
    N = size(x0, 1)
    T = eltype(x0)
    xs = zeros(T, N, m+1)  # Ring buffers storing the iterates
    fs = zeros(T, N, m+1)  # newest to oldest
    xs[:, 1] = x0
    errs = zeros(max_iter)
    err = Inf

    for n = 1:max_iter
        fs[:, 1] = f(xs[:, 1])  # Residual
        err = norm(fs[:, 1])
        errs[n] = err
        println("$n $err")
        if err < tol
            break
        end
        new_x = xs[:, 1] + fs[:, 1]  # Richardson update

        # Anderson acceleration
        m_eff = min(n-1, m)
        if m_eff > 0 && n > warming
            mat = fs[:, 2:m_eff + 1] .- fs[:, 1]
            alphas = -mat \ fs[:, 1]
            # alphas = -(mat'*mat) \ (mat'* (gs[:,1] - xs[:,1]))
            for i = 1:m_eff
                new_x .+= alphas[i] .* (xs[:, i+1] + fs[:, i+1] - xs[:, 1] - fs[:, 1])
            end
        end

        xs = circshift(xs, (0, 1))
        fs = circshift(fs, (0, 1))
        xs[:,1] = new_x
    end
    (fixpoint=xs[:,1], converged=err < tol)
end
function scf_anderson_solver(m=5)
    (f, x0, tol, max_iter) -> anderson(x -> f(x) - x, x0, m, max_iter, tol)
end

"""
CROP-accelerated root-finding iteration for `f`, starting from `x0` and keeping
a history of `m` steps. Optionally `warming` specifies the number of non-accelerated
steps to perform for warming up the history.
"""
function CROP(f, x0, m::Int, max_iter::Int, tol::Real, warming=0)
    # CROP iterates maintain xn and fn (/!\ fn != f(xn)).
    # xtn+1 = xn + fn
    # ftn+1 = f(xtn+1)
    # Determine αi from min ftn+1 + sum αi(fi - ftn+1)
    # fn+1 = ftn+1 + sum αi(fi - ftn+1)
    # xn+1 = xtn+1 + sum αi(xi - xtn+1)
    # Reference:
    # Patrick Ettenhuber and Poul Jørgensen, JCTC 2015, 11, 1518-1524
    # https://doi.org/10.1021/ct501114q

    # Cheat support for multidimensional arrays
    if length(size(x0)) != 1
        x, conv= CROP(x -> vec(f(reshape(x, size(x0)...))), vec(x0), m, max_iter, tol, warming)
        return (fixpoint=reshape(x, size(x0)...), converged=conv)
    end
    N = size(x0,1)
    T = eltype(x0)
    xs = zeros(T, N, m+1)  # Ring buffers storing the iterates
    fs = zeros(T, N, m+1)  # newest to oldest
    xs[:,1] = x0
    fs[:,1] = f(x0)        # Residual
    errs = zeros(max_iter)
    err = Inf

    for n = 1:max_iter
        # println(xs[1:4, 1])
        xtnp1 = xs[:, 1] + fs[:, 1]  # Richardson update
        ftnp1 = f(xtnp1)             # Residual
        err = norm(ftnp1)
        errs[n] = err
        println("$n $err")
        if err < tol
            break
        end

        # CROP acceleration
        m_eff = min(n, m)
        if m_eff > 0 && n > warming
            mat = fs[:, 1:m_eff] .- ftnp1
            alphas = -mat \ ftnp1
            bak_xtnp1 = copy(xtnp1)
            bak_ftnp1 = copy(ftnp1)
            for i = 1:m_eff
                xtnp1 .+= alphas[i].*(xs[:, i] .- bak_xtnp1)
                ftnp1 .+= alphas[i].*(fs[:, i] .- bak_ftnp1)
            end
            # println(norm(ftnp1 - (bak_ftnp1 + mat*alphas)))
        end

        xs = circshift(xs,(0,1))
        fs = circshift(fs,(0,1))
        xs[:,1] = xtnp1
        fs[:,1] = ftnp1
        # fs[:,1] = f(xs[:,1])
    end
    (fixpoint=xs[:, 1], converged=err < tol)
end
scf_CROP_solver(m=5) = (f, x0, tol, max_iter) -> CROP(x -> f(x) - x, x0, m, max_iter, tol)
