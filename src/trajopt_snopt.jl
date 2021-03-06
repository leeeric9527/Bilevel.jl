function traj_fn_snopt(traj_data)
    q0_selector = 1:traj_data.num_q
    v0_selector = q0_selector[end] .+ (1:traj_data.num_v)
    qnext_selector = v0_selector[end] .+ (1:traj_data.num_q)
    vnext_selector = qnext_selector[end] .+ (1:traj_data.num_v)
    input_selector = vnext_selector[end] .+ (1:traj_data.num_v)
    last_selector = input_selector[end]
    if (traj_data.num_slack > 0)
        slack_selector = last_selector .+ (1:traj_data.num_slack)
        last_selector = slack_selector[end]
    end
    if (traj_data.num_contacts > 0 && !traj_data.implicit_contact)
        contact_selector = last_selector .+ (1:traj_data.num_contacts*(2+traj_data.β_dim))
        last_selector = contact_selector[end]
    end

    g_kin_selector = 1:traj_data.num_kin
    g_dyn_selector = g_kin_selector[end] .+ (1:traj_data.num_dyn)
    if (traj_data.num_contacts > 0)
        g_dist_selector = g_dyn_selector[end] .+ (1:traj_data.num_dist)
        if traj_data.implicit_contact
            num_dyn_contact = traj_data.num_v
            num_comp_contact = traj_data.num_contacts*(2+traj_data.β_dim)
            num_pos_contact = traj_data.num_contacts*(1+traj_data.β_dim) + 2*traj_data.num_contacts*(2+traj_data.β_dim)
            contact_x0 = zeros(traj_data.num_contacts*(2+traj_data.β_dim))
            contact_λ0 = zeros(num_dyn_contact+num_comp_contact)
            contact_μ0 = zeros(num_pos_contact)
        else
            g_comp_selector = g_dist_selector[end] .+ (1:traj_data.num_comp)
            g_pos_selector = g_comp_selector[end] .+ (1:traj_data.num_pos)
        end
    end

    function eval_dyn(x::AbstractArray{T}) where T
        q0 = x[q0_selector]
        v0 = x[v0_selector]

        qnext = x[qnext_selector]
        vnext = x[vnext_selector]
        u0 = x[input_selector]

        if (traj_data.num_slack > 0)
            slack = x[slack_selector]
        end

        x0 = MechanismState{T}(traj_data.mechanism)
        set_configuration!(x0,q0)
        set_velocity!(x0,v0)

        xnext = MechanismState{T}(traj_data.mechanism)
        set_configuration!(xnext, qnext)
        set_velocity!(xnext, vnext)

        H = mass_matrix(x0)

        if (traj_data.num_contacts > 0)
            Dtv = Matrix{T}(undef, traj_data.β_dim,traj_data.num_contacts)
            rel_transforms = Vector{Tuple{Transform3D{T}, Transform3D{T}}}(undef, traj_data.num_contacts) # force transform, point transform
            geo_jacobians = Vector{GeometricJacobian{Matrix{T}}}(undef, traj_data.num_contacts)
            geo_jacobians_surfaces = Vector{Union{Nothing,GeometricJacobian{Matrix{T}}}}(undef, sim_data.num_contacts)
            ϕs = Vector{T}(undef, traj_data.num_contacts)
            for i = 1:traj_data.num_contacts
                v = point_velocity(twist_wrt_world(xnext,traj_data.bodies[i]), transform_to_root(xnext, traj_data.contact_points[i].frame) * traj_data.contact_points[i])
                Dtv[:,i] = map(traj_data.Ds[i]) do d
                    dot(transform_to_root(xnext, d.frame) * d, v)
                end
                rel_transforms[i] = (relative_transform(xnext, traj_data.obstacles[i].contact_face.outward_normal.frame, traj_data.world_frame),
                                              relative_transform(xnext, traj_data.contact_points[i].frame, traj_data.world_frame))
                geo_jacobians[i] = geometric_jacobian(xnext, traj_data.paths[i])
                if !isa(sim_data.surface_paths[i],Nothing)
                    geo_jacobians_surfaces[i] = geometric_jacobian(xnext, sim_data.surface_paths[i])
                else
                    geo_jacobians_surfaces[i] = nothing
                end
                ϕs[i] = separation(traj_data.obstacles[i], transform(xnext, traj_data.contact_points[i], traj_data.obstacles[i].contact_face.outward_normal.frame))
            end
        end

        config_derivative = configuration_derivative(xnext)
        HΔv = H * (vnext - v0)
        bias = u0 .- dynamics_bias(xnext)

        if (traj_data.num_contacts > 0)
            if traj_data.implicit_contact
                contact_x0_sol, contact_λ0_sol, contact_μ0_sol = solve_implicit_contact_τ(sim_data,ϕs,Dtv,rel_transforms,geo_jacobians,geo_jacobians_surfaces,HΔv,bias,contact_x0,contact_λ0,contact_μ0)
                contact_bias = τ_total(contact_x0_sol,rel_transforms,geo_jacobians,geo_jacobians_surfaces,sim_data)
            else
                contact_bias = τ_total(x[contact_selector],rel_transforms,geo_jacobians,traj_data)
            end
        else
            contact_bias = zeros(traj_data.num_v)
        end

        g = zeros(T, traj_data.num_dyn_eq+traj_data.num_dyn_ineq)

        # == 0
        g[g_kin_selector] = qnext .- q0 .- traj_data.Δt .* config_derivative
        g[g_dyn_selector] = HΔv .- traj_data.Δt .* (bias .- contact_bias)

        # <= 0
        if (traj_data.num_contacts > 0)
            g[g_dist_selector] = -ϕs
            if !traj_data.implicit_contact
                g[g_comp_selector] = complementarity_contact_constraints_relaxed(x[contact_selector],slack,ϕs,Dtv,traj_data)
                g[g_pos_selector] = pos_contact_constraints(x[contact_selector],Dtv,traj_data)
            end
        end

        g
    end

    function eval_con(xv::AbstractArray{T}) where T
        x = reshape(xv,traj_data.num_xn,traj_data.N)
        geq = zeros(T,traj_data.num_eq)
        gineq = zeros(T,traj_data.num_ineq)
        for i = 1:traj_data.N-1
            xn = vcat(x[1:traj_data.num_q+traj_data.num_v,i],x[:,i+1])
            gn = eval_dyn(xn)
            geq[(i-1)*traj_data.num_dyn_eq+1:i*traj_data.num_dyn_eq] = gn[1:traj_data.num_dyn_eq]
            gineq[(i-1)*traj_data.num_dyn_ineq+1:i*traj_data.num_dyn_ineq] = gn[traj_data.num_dyn_eq+1:traj_data.num_dyn_eq+traj_data.num_dyn_ineq]
        end

        # TODO handle more types of constraints
        glasteqi = (traj_data.N-1)*traj_data.num_dyn_eq
        glastineqi = (traj_data.N-1)*traj_data.num_dyn_ineq
        for i = 1:length(traj_data.state_eq)
            gi = traj_data.state_eq[i][1](x[1:traj_data.num_q+traj_data.num_v,traj_data.state_eq[i][2]])
            geq[glasteqi+1:glasteqi+traj_data.num_q+traj_data.num_v] = gi
            glasteqi += traj_data.num_q+traj_data.num_v
        end
        for i = 1:length(traj_data.fn_ineq)
            gi = traj_data.fn_ineq[i][1](x[1:traj_data.num_q,traj_data.fn_ineq[i][2]])
            gineq[glastineqi+1] = gi
            glastineqi += 1
        end

        g = vcat(geq,gineq)

        g
    end

    input_selector_full = traj_data.num_q + traj_data.num_v + (1:traj_data.num_v)
    vel_selector_full = traj_data.num_q + (1:traj_data.num_v)
    function eval_f(xv)
        x = reshape(xv,traj_data.num_xn,traj_data.N)
        J = 0.

        if traj_data.min_τ
            u = x[input_selector_full,:]
            J += .5*sum(u.^2)
        end

        if traj_data.min_v
            v = x[vel_selector_full,:]
            J += .5*sum(v.^2)
        end

        for i = 1:length(traj_data.fn_obj)
            J += traj_data.fn_obj[i][1](x[1:traj_data.num_q,traj_data.fn_obj[i][2]])
        end

        J
    end

    # fres = DiffResults.GradientResult(zeros(num_x))
    # gres = DiffResults.JacobianResult(zeros(num_eq+num_ineq), zeros(num_x))
    # fcfg = ForwardDiff.GradientConfig(eval_f, zeros(num_x))
    # gcfg = ForwardDiff.JacobianConfig(eval_con, zeros(num_x))
    function update_fn(x)
        # ForwardDiff.gradient!(fres, eval_f, x, fcfg)
        # J = DiffResults.value(x)
        # gJ = DiffResults.gradient(x)
        J = eval_f(x)
        gJ = ForwardDiff.gradient(eval_f, x)

        # ForwardDiff.jacobian!(gres, eval_con, x, gcfg)
        # g = DiffResults.value(gres)
        g = eval_con(x)
        ceq = g[1:traj_data.num_eq]
        c = g[traj_data.num_eq+1:traj_data.num_eq+traj_data.num_ineq]
        # dgdx = DiffResults.jacobian(gres)
        dgdx = ForwardDiff.jacobian(eval_con, x)
        gceq = dgdx[1:traj_data.num_eq,:]
        gc = dgdx[traj_data.num_eq+1:traj_data.num_eq+traj_data.num_ineq,:]

        fail = false

        J, c, ceq, gJ, gc, gceq, fail
    end

    update_fn
end

function trajopt_snopt(traj_data;opt_tol=1e-6,major_feas=1e-6,minor_feas=1e-6)
    # optimization bounds
    x_L = -1e19 * ones(traj_data.num_x)
    x_U = 1e19 * ones(traj_data.num_x)

    traj_fn = traj_fn_snopt(traj_data)

    options = Dict{String, Any}()
    options["Derivative option"] = 1
    options["Verify level"] = -1 # -1 = 0ff, 0 = cheap
    options["Major optimality tolerance"] = opt_tol
    options["Major feasibility tolerance"] = major_feas
    options["Minor feasibility tolerance"] = minor_feas
    # options["Feasible point"] = true

    x0 = zeros(traj_data.num_xn,traj_data.N)
    x0[1,:] .= 1. # quaternion
    x0 = x0[:]

    xopt, fopt, info = snopt(traj_fn, x0, x_L, x_U, options)
    println(info)

    reshape(xopt,traj_data.num_xn,traj_data.N)
end
