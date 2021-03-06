function update_constraints_ipopt(traj_data)
    num_slack = 1
    num_kin = traj_data.num_q
    num_dyn = traj_data.num_v
    num_comp = traj_data.num_contacts*(2+traj_data.β_dim)
    num_dist = traj_data.num_contacts
    num_pos = traj_data.num_contacts*(1+traj_data.β_dim)

    q0_selector = 1:traj_data.num_q
    v0_selector = traj_data.num_q+1:traj_data.num_q+traj_data.num_v
    qnext_selector = traj_data.num_q+traj_data.num_v:2*traj_data.num_q+traj_data.num_v
    vnext_selector = 2*traj_data.num_q+traj_data.num_v+1:2*traj_data.num_q+2*traj_data.num_v
    slack_selector = 2*traj_data.num_q+2*traj_data.num_v+1:2*traj_data.num_q+2*traj_data.num_v+num_slack
    contact_selector =
    2*traj_data.num_q+2*traj_data.num_v+num_slack+1:2*traj_data.num_q+2*traj_data.num_v+num_slack+traj_data.num_contacts*(2+traj_data.β_dim)

    g_kin_selector = 1:num_kin
    g_dyn_selector = num_kin+1:num_kin+num_dyn
    g_comp_selector = num_kin+num_dyn+1:num_kin+num_dyn+num_comp
    g_dist_selector = num_kin+num_dyn+num_comp+1:num_kin+num_dyn+num_comp+num_dist
    g_pos_selector = num_kin+num_dyn+num_comp+num_dist+1:num_kin+num_dyn+num_comp+num_dist+num_pos

    num_eq = num_kin+num_dyn
    num_ineq = num_comp+num_dist+num_pos

    function eval_g(x::AbstractArray{T}, g) where T
        q0 = x[q0_selector]
        v0 = x[v0_selector]

        qnext = x[qnext_selector]
        vnext = x[vnext_selector]

        slack = x[slack_selector]
        xcontact = x[contact_selector]

        x0 = MechanismState{T}(traj_data.mechanism)
        set_configuration!(x0,q0)
        set_velocity!(x0,v0)

        xnext = MechanismState{T}(traj_data.mechanism)
        set_configuration!(xnext, qnext)
        set_velocity!(xnext, vnext)

        H = mass_matrix(x0)

        Dtv = Matrix{T}(traj_data.β_dim,traj_data.num_contacts)
        rel_transforms = Vector{Tuple{Transform3D{T}, Transform3D{T}}}(traj_data.num_contacts) # force transform, point transform
        geo_jacobians = Vector{GeometricJacobian{Matrix{T}}}(traj_data.num_contacts)
        ϕs = Vector{T}(traj_data.num_contacts)
        for i = 1:traj_data.num_contacts
            v = point_velocity(twist_wrt_world(xnext,traj_data.bodies[i]), transform_to_root(xnext, traj_data.contact_points[i].frame) * traj_data.contact_points[i])
            Dtv[:,i] = map(traj_data.Ds[i]) do d
                dot(transform_to_root(xnext, d.frame) * d, v)
            end
            rel_transforms[i] = (relative_transform(xnext, traj_data.obstacles[i].contact_face.outward_normal.frame, traj_data.world_frame),
                                          relative_transform(xnext, traj_data.contact_points[i].frame, traj_data.world_frame))
            geo_jacobians[i] = geometric_jacobian(xnext, traj_data.paths[i])
            ϕs[i] = separation(traj_data.obstacles[i], transform(xnext, traj_data.contact_points[i], traj_data.obstacles[i].contact_face.outward_normal.frame))
        end

        config_derivative = configuration_derivative(xnext)
        HΔv = H * (vnext - v0)
        bias = u0 .- dynamics_bias(xnext)
        contact_bias = τ_total(xcontact,rel_transforms,geo_jacobians,traj_data)

        # == 0
        g[g_kin_selector] = qnext .- q0 .- traj_data.Δt .* config_derivative
        g[g_dyn_selector] = HΔv .- traj_data.Δt .* (bias .- contact_bias)

        # <= 0
        g[g_comp_selector] = complementarity_contact_constraints_relaxed(xcontact,slack,ϕs,Dtv,traj_data)
        g[g_dist_selector] = -ϕs
        g[g_pos_selector] = pos_contact_constraints(xcontact,Dtv,traj_data)
    end

    eval_g, num_eq, num_ineq
end

function traj_constraints_ipopt(traj_data,N)
    num_xn = traj_data.num_q+traj_data.num_v+traj_data.num_slack+traj_data.num_contacts*(2+traj_data.β_dim)
    dyn_con, num_dyn_eq, num_dyn_ineq = update_constraints(traj_data)

    num_x = N*num_xn
    num_eq = (N-1)*num_dyn_eq
    num_ineq = (N-1)*num_dyn_ineq
    gn = zeros(num_dyn_eq+num_dyn_ineq)

    function eval_g(xv::AbstractArray{T}, g) where T
        x = reshape(xv,num_x,N) # don't reshape
        # dynamics
        for i = 1:N-1
            xn = vcat(x[1:traj_data.num_q+traj_data.num_v,i],x[:,i+1])
            # make this in place
            dyn_con(xn, gn)
            g[(i-1)*num_dyn_eq+1:i*num_dyn_eq] = gn[1:num_dyn_eq]
            g[(num_eq+(i-1)*num_dyn_ineq+1:num_eq+i*num_dyn_ineq] = gn[num_dyn_eq+1:num_dyn_eq+num_dyn_ineq]
        end
    end

    function eval_jac_g(x, mode, rows, cols, values)
        if mode == :Structure
            # TODO actually figure out the sparsity pattern
            for i = 1:(num_eq + num_ineq)
                for j = 1:num_x
                    rows[(i-1)*num_x+j] = i
                    cols[(i-1)*num_x+j] = j
                end
            end
        else
            g = zeros(num_eq + num_ineq)
            J = ForwardDiff.jacobian((g̃, x̃) -> eval_g(x̃, g̃), g, x)
            values[:] = J'[:]
        end
    end

    eval_g, eval_jac_g, num_h, num_g
end

function trajopt_ipopt(mechanism::Mechanism,
                 env::Environment,
                 Δt::Real,
                 N::Integer,
                 implicit_contact=true)

    traj_data = get_traj_data(mechanism,env,Δt)

    if implicit_contact
        num_xn = traj_data.num_q+traj_data.num_v
    else
        num_xn = traj_data.num_q+traj_data.num_v+1+traj_data.num_contacts*(2+traj_data.β_dim)
    end
    num_x = N*num_xn

    # optimization bounds
    x_L = -1e19 * ones(num_x)
    x_U = 1e19 * ones(num_x)
    if !implicit_contact
        for i=1:N
            istart =
            iend =
            x_L[istart:iend] .= 0.
            x_U[istart:iend] .= 100.
        end
    end

    g_L = vcat(0. * ones(traj_data.num_h), -1e19 * ones(traj_data.num_g))
    g_U = vcat(0. * ones(traj_data.num_h),    0. * ones(traj_data.num_g))

    if implicit_contact
        results = vcat(configuration(state0),velocity(state0),zeros(traj_data.num_slack))
    else
        results = vcat(configuration(state0),velocity(state0),zeros(traj_data.num_slack),zeros(traj_data.num_contacts*(2+traj_data.β_dim)))
    end

    eval_f = x -> begin
        slack = x[traj_data.num_q+traj_data.num_v+1:traj_data.num_q+traj_data.num_v+traj_data.num_slack]
        .5*slack'*slack
    end
    eval_grad_f = (x, grad_f) -> begin
        grad_f[:] = 0
        slack = x[traj_data.num_q+traj_data.num_v+1:traj_data.num_q+traj_data.num_v+traj_data.num_slack]
        grad_f[traj_data.num_q+traj_data.num_v+1:traj_data.num_q+traj_data.num_v+traj_data.num_slack] = slack
    end

    x_ctrl = MechanismState(traj_data.mechanism)
    u0 = zeros(traj_data.num_v)

    for i in 1:N
        x = results[:,end]
        q0 = x[1:traj_data.num_q]
        v0 = x[traj_data.num_q+1:traj_data.num_q+traj_data.num_v]

        set_configuration!(x_ctrl,q0)
        set_velocity!(x_ctrl,v0)
        setdirty!(x_ctrl)
        control!(u0, (i-1)*traj_data.Δt, x_ctrl)

        if implicit_contact
            eval_g, eval_jac_g = update_constraints_implicit_contact(traj_data,q0,v0,u0)
        else
            eval_g, eval_jac_g = update_constraints(traj_data,q0,v0,u0)
        end

        prob = createProblem(traj_data.num_x,x_L,x_U,
                             traj_data.num_h+traj_data.num_g,g_L,g_U,
                             traj_data.num_x*(traj_data.num_h+traj_data.num_g),0,
                             eval_f,eval_g,
                             eval_grad_f,eval_jac_g)

        prob.x[:] = results[1:traj_data.num_x,end][:]

        addOption(prob, "hessian_approximation", "limited-memory")
        addOption(prob, "print_level", 1)
        addOption(prob, "tol", 1e-8) # convergence tol default 1e-8
        addOption(prob, "constr_viol_tol", 1e-4) # default 1e-4

        status = solveProblem(prob)
        println(Ipopt.ApplicationReturnStatus[status])

        results = hcat(results,prob.x)
    end

    results
end
