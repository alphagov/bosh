require 'spec_helper'

module Bosh::Director
  module DeploymentPlan
    describe InstanceGroupSpecParser do
      subject(:parser) { described_class.new(deployment_plan, event_log, logger) }

      let(:deployment_plan) do
        instance_double(
          Planner,
          model: deployment_model,
          properties: {},
          update: UpdateConfig.new(
            'canaries' => 2,
            'max_in_flight' => 4,
            'canary_watch_time' => 60000,
            'update_watch_time' => 30000,
            'serial' => true,
          ),
          name: 'fake-deployment',
          networks: [network],
          releases: {}
        )
      end
      let(:deployment_model) { Models::Deployment.make }
      let(:network) { ManualNetwork.new('fake-network-name', [], logger) }
      let(:task) { Models::Task.make(id: 42) }
      let(:task_writer) { Bosh::Director::TaskDBWriter.new(:event_output, task.id) }
      let(:event_log) { Bosh::Director::EventLog::Log.new(task_writer) }

      let(:disk_collection) { PersistentDiskCollection.new(logger) }

      let(:links_manager_factory) do
        instance_double(Bosh::Director::Links::LinksManagerFactory).tap do |double|
          expect(double).to receive(:create_manager).and_return(links_manager)
        end
      end

      let(:links_manager) do
        instance_double(Bosh::Director::Links::LinksManager).tap do |double|
          allow(double).to receive(:find_providers).and_return([])
          allow(double).to receive(:resolve_deployment_links)
        end
      end

      let(:provider) { instance_double(Bosh::Director::Models::Links::LinkProvider) }
      let(:consumer) { instance_double(Bosh::Director::Models::Links::LinkConsumer) }
      let(:provider_intent) { instance_double(Bosh::Director::Models::Links::LinkProviderIntent) }
      let(:consumer_intent) { instance_double(Bosh::Director::Models::Links::LinkConsumerIntent) }

      before do
        allow(Bosh::Director::Links::LinksManagerFactory).to receive(:create).and_return(links_manager_factory)
        allow(links_manager).to receive(:find_or_create_provider).and_return(provider)
        allow(links_manager).to receive(:find_or_create_consumer).and_return(consumer)
        allow(links_manager).to receive(:find_or_create_provider_intent).and_return(provider_intent)
        allow(links_manager).to receive(:find_or_create_consumer_intent).and_return(consumer_intent)
      end

      describe '#parse' do
        before do
          allow(deployment_plan).to receive(:resource_pool).and_return(resource_pool)
          allow(resource_pool).to receive(:name).and_return('fake-vm-type')
          allow(resource_pool).to receive(:cloud_properties).and_return({})
          allow(resource_pool).to receive(:stemcell).and_return(
            Stemcell.parse({
              'name' => 'fake-stemcell-name',
              'version' => 1
            })
          )
          allow(deployment_plan).to receive(:disk_type).and_return(disk_type)
          allow(deployment_plan).to receive(:release).and_return(job_rel_ver)
          allow(PersistentDiskCollection).to receive(:new).and_return(disk_collection)
        end
        let(:parse_options) { {} }
        let(:parsed_instance_group) { parser.parse(instance_group_spec, parse_options) }
        let(:resource_pool_env) { {'key' => 'value'} }
        let(:uninterpolated_resource_pool_env) { {'key' => '((value_placeholder))'} }
        let(:resource_pool) do
          instance_double(ResourcePool, env: resource_pool_env)
        end
        let(:disk_type) { instance_double(DiskType) }
        let(:job_rel_ver) { instance_double(ReleaseVersion, template: nil) }

        let(:instance_group_spec) do
          {
            'name' => 'instance-group-name',
            'jobs' => [],
            'release' => 'fake-release-name',
            'resource_pool' => 'fake-resource-pool-name',
            'instances' => 1,
            'networks' => [{'name' => 'fake-network-name'}],
          }
        end

        it 'sets deployment name to instance group' do
          instance_group = parsed_instance_group
          expect(instance_group.deployment_name).to eq('fake-deployment')
        end

        describe 'name key' do
          it 'parses name' do
            instance_group = parsed_instance_group
            expect(instance_group.name).to eq('instance-group-name')
          end
        end

        describe 'lifecycle key' do
          InstanceGroup::VALID_LIFECYCLE_PROFILES.each do |profile|
            it "is able to parse '#{profile}' as lifecycle profile" do
              instance_group_spec.merge!('lifecycle' => profile)
              instance_group = parsed_instance_group
              expect(instance_group.lifecycle).to eq(profile)
            end
          end

          it "defaults lifecycle profile to 'service'" do
            instance_group_spec.delete('lifecycle')
            instance_group = parsed_instance_group
            expect(instance_group.lifecycle).to eq('service')
          end

          it 'raises an error if lifecycle profile value is not known' do
            instance_group_spec['lifecycle'] = 'unknown'

            expect {
              parsed_instance_group
            }.to raise_error(
              JobInvalidLifecycle,
              "Invalid lifecycle 'unknown' for 'instance-group-name', valid lifecycle profiles are: service, errand",
            )
          end
        end

        describe 'release key' do
          it 'parses release' do
            instance_group = parsed_instance_group
            expect(instance_group.release).to eq(job_rel_ver)
          end

          it 'complains about unknown release' do
            instance_group_spec['release'] = 'unknown-release-name'
            expect(deployment_plan).to receive(:release)
                                         .with('unknown-release-name')
                                         .and_return(nil)

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupUnknownRelease,
              "Instance group 'instance-group-name' references an unknown release 'unknown-release-name'",
            )
          end

          context 'when there is no job-level release defined' do
            before { instance_group_spec.delete('release') }

            context 'when the deployment has zero releases'

            context 'when the deployment has exactly one release' do
              it "picks the deployment's release" do
                deployment_release = instance_double(ReleaseVersion, name: '')
                allow(deployment_plan).to receive(:releases).and_return([deployment_release])

                instance_group = parsed_instance_group
                expect(instance_group.release).to eq(deployment_release)
              end
            end

            context 'when the deployment has more than one release' do
              it 'does not pick a release' do
                instance_group_spec.delete('release')

                allow(deployment_plan).to receive(:releases).and_return([instance_double(ReleaseVersion, name: ''), instance_double(ReleaseVersion, name: '')])

                instance_group = parsed_instance_group
                expect(instance_group.release).to be_nil
              end
            end
          end
        end

        describe 'job key' do
          before { instance_group_spec.delete('jobs') }

          it 'parses a single job' do
            instance_group_spec['template'] = 'job-name'

            expect(deployment_plan).to receive(:release)
                                         .with('fake-release-name')
                                         .and_return(job_rel_ver)

            job = make_job('job-name', job_rel_ver)
            expect(job).to receive(:add_properties)
                             .with({}, 'instance-group-name')
            expect(job_rel_ver).to receive(:get_or_create_template)
                                     .with('job-name')
                                     .and_return(job)

            instance_group = parsed_instance_group
            expect(instance_group.jobs).to eq([job])
          end

          it 'does not issue a deprecation warning when Template has a single value' do
            instance_group_spec['template'] = 'fake-template-name'

            allow(deployment_plan).to receive(:release)
                                        .with('fake-release-name')
                                        .and_return(job_rel_ver)

            job1 = make_job('fake-template-name', job_rel_ver)
            allow(job1).to receive(:add_properties)

            allow(job_rel_ver).to receive(:get_or_create_template)
                                    .with('fake-template-name')
                                    .and_return(job1)

            expect(Config.event_log).not_to receive(:warn_deprecated)
            parsed_instance_group
          end

          it 'parses multiple templates' do
            instance_group_spec['template'] = %w( fake-template1-name fake-template2-name )

            expect(deployment_plan).to receive(:release)
                                         .with('fake-release-name')
                                         .and_return(job_rel_ver)

            job1 = make_job('fake-template1-name', job_rel_ver)
            expect(job1).to receive(:add_properties)
                              .with({}, 'instance-group-name')
            expect(job_rel_ver).to receive(:get_or_create_template)
                                     .with('fake-template1-name')
                                     .and_return(job1)

            job2 = make_job('fake-template2-name', job_rel_ver)
            expect(job2).to receive(:add_properties)
                              .with({}, 'instance-group-name')
            expect(job_rel_ver).to receive(:get_or_create_template)
                                     .with('fake-template2-name')
                                     .and_return(job2)

            instance_group = parsed_instance_group
            expect(instance_group.jobs).to eq([job1, job2])
          end

          it 'issues a deprecation warning when Template has an array value' do
            instance_group_spec['template'] = %w( fake-template1-name fake-template2-name )

            allow(deployment_plan).to receive(:release)
                                        .with('fake-release-name')
                                        .and_return(job_rel_ver)

            job1 = make_job('fake-template1-name', job_rel_ver)
            allow(job1).to receive(:add_properties)

            allow(job_rel_ver).to receive(:get_or_create_template)
                                    .with('fake-template1-name')
                                    .and_return(job1)

            job2 = make_job('fake-template2-name', job_rel_ver)
            allow(job2).to receive(:add_properties)

            allow(job_rel_ver).to receive(:get_or_create_template)
                                    .with('fake-template2-name')
                                    .and_return(job2)

            expect(event_log).to receive(:warn_deprecated).with(
              "Please use 'templates' when specifying multiple templates for a job. "\
                "'template' for multiple templates will soon be unsupported."
            )
            parsed_instance_group
          end

          it 'raises an error when a job has no release' do
            instance_group_spec['template'] = 'fake-template-name'
            instance_group_spec.delete('release')

            fake_releases = 2.times.map {
              instance_double(
                ReleaseVersion,
                template: nil,
              )
            }
            expect(deployment_plan).to receive(:releases).and_return(fake_releases)

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupMissingRelease,
              "Cannot tell what release job 'instance-group-name' is supposed to use, please explicitly specify one",
            )
          end

          it 'adds merged global & instance group properties to template(s)' do
            allow(deployment_plan).to receive(:properties)
                                        .and_return({
                                          'property_1' => 'woof',
                                          'deployment_plan_property_1' => 'smurf'
                                        })

            instance_group_spec['template'] = %w( fake-template1-name fake-template2-name )

            instance_group_spec['properties'] = {
              'instance_group_property_1' => 'moop',
              'property_1' => 'meow'
            }

            expect(deployment_plan).to receive(:release)
                                         .with('fake-release-name')
                                         .and_return(job_rel_ver)

            job1 = make_job('fake-template1-name', job_rel_ver)
            expect(job1).to receive(:add_properties)
                              .with({
                                'instance_group_property_1' => 'moop',
                                'property_1' => 'meow',
                                'deployment_plan_property_1' => 'smurf'
                              }, 'instance-group-name')
            allow(job_rel_ver).to receive(:get_or_create_template)
                                    .with('fake-template1-name')
                                    .and_return(job1)

            job2 = make_job('fake-template2-name', job_rel_ver)
            expect(job2).to receive(:add_properties)
                              .with({
                                'instance_group_property_1' => 'moop',
                                'property_1' => 'meow',
                                'deployment_plan_property_1' => 'smurf'
                              }, 'instance-group-name')
            allow(job_rel_ver).to receive(:get_or_create_template)
                                    .with('fake-template2-name')
                                    .and_return(job2)

            instance_group = parsed_instance_group
            expect(instance_group.jobs).to eq([job1, job2])
          end

        end

        shared_examples_for 'templates/jobs key' do
          before { instance_group_spec.delete('jobs') }

          # TODO LINKS: Add tests to ensure links_manager's methods get invoked.
          context 'when value is an array of hashes' do
            context 'when one of the hashes specifies a release' do
              before do
                instance_group_spec[keyword] = [{
                  'name' => 'job-name',
                  'release' => 'fake-release',
                  'consumes' => {'a' => {'from' => 'link_name'}}
                }]
                release_model_1 = Models::Release.make(name: 'fake-release-1')
                version = Models::ReleaseVersion.make(version: '1.0.0')
                release_model_1.add_version(version)

                release_model_2 = Models::Release.make(name: 'fake-release-2')
                fake_release_version_model = Models::ReleaseVersion.make(version: '1', release: release_model_2)
                fake_release_version_model.add_template(Models::Template.make(
                  name: 'job-name',
                  release: release_model_2,
                  spec: {consumes: [{'name' => "a", 'type' => "db"}]}
                ))

                deployment_model = Models::Deployment.make(name: 'deployment')
                version.add_deployment(deployment_model)
              end

              let(:rel_ver) { instance_double(ReleaseVersion, name: 'fake-release-2', version: '1') }

              context 'when job specifies a release' do
                before do
                  instance_group_spec['release'] = 'fake-release'

                end
                let(:job) { make_job('job-name', rel_ver) }

                before do
                  allow(deployment_plan).to receive(:release)
                                              .with('fake-release')
                                              .and_return(rel_ver)

                  allow(rel_ver).to receive(:get_or_create_template)
                                      .with('job-name')
                                      .and_return(job)
                  allow(job).to receive(:add_properties)
                end

                it 'sets job template from release specified in a hash' do
                  allow(consumer_intent).to receive(:name=)
                  allow(consumer_intent).to receive(:blocked=)
                  allow(consumer_intent).to receive(:optional=)
                  allow(consumer_intent).to receive(:metadata=)
                  allow(consumer_intent).to receive(:save)

                  instance_group = parsed_instance_group
                  expect(instance_group.jobs).to eq([job])
                end
              end

              context 'when job does not specify a release' do
                before { instance_group_spec.delete('release') }

                before { allow(deployment_plan).to receive(:releases).and_return([deployment_rel_ver]) }
                let(:deployment_rel_ver) { instance_double(ReleaseVersion, name: '') }
                let(:job) { make_job('job-name', nil) }

                let(:provides_link) { instance_double(Link, name: 'zz') }
                let(:provides_job) { instance_double(Job, name: 'z') }
                let(:provides_instance_group) { instance_double(InstanceGroup, name: 'y') }

                before do
                  allow(deployment_plan).to receive(:release)
                                              .with('fake-release')
                                              .and_return(rel_ver)

                  allow(provides_job).to receive(:provided_links).and_return([provides_link])
                  allow(provides_instance_group).to receive(:jobs).and_return([provides_job])
                  allow(deployment_plan).to receive(:instance_groups).and_return([provides_instance_group])

                  allow(rel_ver).to receive(:get_or_create_template)
                                      .with('job-name')
                                      .and_return(job)
                  allow(job).to receive(:add_link_from_manifest)
                  allow(job).to receive(:add_properties)
                end

                it 'sets job template from release specified in a hash' do
                  allow(consumer_intent).to receive(:name=)
                  allow(consumer_intent).to receive(:blocked=)
                  allow(consumer_intent).to receive(:optional=)
                  allow(consumer_intent).to receive(:metadata=)
                  allow(consumer_intent).to receive(:save)

                  instance_group = parsed_instance_group
                  expect(instance_group.jobs).to eq([job])
                end
              end
            end

            context 'when one of the hashes does not specify a release' do

              let(:job_rel_ver) do
                instance_double(
                  ReleaseVersion,
                  name: 'fake-template-release',
                  version: '1',
                  template: nil,
                )
              end

              before do
                instance_group_spec[keyword] = [{'name' => 'job-name', 'links' => {'db' => 'a.b.c'}}]
                release_model = Models::Release.make(name: 'fake-template-release')
                release_version_model = Models::ReleaseVersion.make(version: '1', release: release_model)
                release_version_model.add_template(Models::Template.make(name: 'job-name', release: release_model))
              end

              context 'when job specifies a release' do
                before { instance_group_spec['release'] = 'fake-job-release' }

                it 'sets job template from job release' do
                  allow(deployment_plan).to receive(:release)
                                              .with('fake-job-release')
                                              .and_return(job_rel_ver)

                  job = make_job('job-name', nil)
                  allow(job).to receive(:add_properties)
                  expect(job_rel_ver).to receive(:get_or_create_template)
                                           .with('job-name')
                                           .and_return(job)

                  instance_group = parsed_instance_group
                  expect(instance_group.jobs).to eq([job])
                end
              end

              context 'when job does not specify a release' do
                before { instance_group_spec.delete('release') }

                context 'when deployment has multiple releases' do
                  before { allow(deployment_plan).to receive(:releases).and_return([deployment_rel_ver, deployment_rel_ver]) }
                  let(:deployment_rel_ver) { instance_double(ReleaseVersion, name: '') }

                  it 'raises an error because there is not default release specified' do
                    expect {
                      parsed_instance_group
                    }.to raise_error(
                      InstanceGroupMissingRelease,
                      "Cannot tell what release template 'job-name' (instance group 'instance-group-name') is supposed to use, please explicitly specify one",
                    )
                  end
                end

                context 'when deployment has a single release' do
                  let(:deployment_rel_ver) { instance_double(ReleaseVersion, name: 'fake-template-release', version: '1') }
                  let(:job) { make_job('job-name', nil) }
                  before do
                    allow(deployment_plan).to receive(:releases).and_return([deployment_rel_ver])
                    allow(job).to receive(:add_properties)
                  end

                  it 'sets job template from deployment release because first release assumed as default' do
                    expect(deployment_rel_ver).to receive(:get_or_create_template)
                                                    .with('job-name')
                                                    .and_return(job)

                    instance_group = parsed_instance_group
                    expect(instance_group.jobs).to eq([job])
                  end
                end

                context 'when deployment has 0 releases' do
                  before { allow(deployment_plan).to receive(:releases).and_return([]) }

                  it 'raises an error because there is not default release specified' do
                    expect {
                      parsed_instance_group
                    }.to raise_error(
                      InstanceGroupMissingRelease,
                      "Cannot tell what release template 'job-name' (instance group 'instance-group-name') is supposed to use, please explicitly specify one",
                    )
                  end
                end
              end
            end

            context 'when one of the hashes specifies a release not specified in a deployment' do
              before do
                instance_group_spec[keyword] = [{
                  'name' => 'job-name',
                  'release' => 'fake-release',
                }]
              end

              it 'raises an error because all referenced releases need to be specified under releases' do
                instance_group_spec['name'] = 'instance-group-name'

                expect(deployment_plan).to receive(:release)
                                             .with('fake-release')
                                             .and_return(nil)

                expect {
                  parsed_instance_group
                }.to raise_error(
                  InstanceGroupUnknownRelease,
                  "Job 'job-name' (instance group 'instance-group-name') references an unknown release 'fake-release'",
                )
              end
            end

            context 'when multiple hashes have the same name' do
              before do
                instance_group_spec[keyword] = [
                  {'name' => 'job-name1'},
                  {'name' => 'job-name2'},
                  {'name' => 'job-name1'},
                ]
              end

              before do # resolve release and template objs
                instance_group_spec['release'] = 'fake-job-release'

                release_model = Models::Release.make(name: 'fake-release')
                release_version_model = Models::ReleaseVersion.make(version: '1', release: release_model)
                release_version_model.add_template(Models::Template.make(name: 'job-name1', release: release_model))
                release_version_model.add_template(Models::Template.make(name: 'job-name2', release: release_model))
                release_version_model.add_template(Models::Template.make(name: 'job-name3', release: release_model))

                job_rel_ver = instance_double(ReleaseVersion, name: 'fake-release', version: '1')
                allow(deployment_plan).to receive(:release)
                                            .with('fake-job-release')
                                            .and_return(job_rel_ver)

                allow(job_rel_ver).to receive(:get_or_create_template) do |name|
                  job = instance_double(Job, name: name)
                  allow(job).to receive(:add_properties)
                  job
                end
              end

              it 'raises an error because job dirs on a VM will become ambiguous' do
                instance_group_spec['name'] = 'fake-instance-group-name'
                expect {
                  parsed_instance_group
                }.to raise_error(
                  InstanceGroupInvalidTemplates,
                  "Colocated job 'job-name1' is already added to the instance group 'fake-instance-group-name'",
                )
              end
            end

            context 'when multiple hashes reference different releases' do
              before do
                release_model_1 = Models::Release.make(name: 'release1')
                release_version_model_1 = Models::ReleaseVersion.make(version: '1', release: release_model_1)
                release_version_model_1.add_template(Models::Template.make(name: 'job-name1', release: release_model_1))

                release_model_2 = Models::Release.make(name: 'release2')
                release_version_model_2 = Models::ReleaseVersion.make(version: '1', release: release_model_2)
                release_version_model_2.add_template(Models::Template.make(name: 'job-name2', release: release_model_2))
              end

              it 'uses the correct release for each template' do
                instance_group_spec[keyword] = [
                  {'name' => 'job-name1', 'release' => 'release1', 'links' => {}},
                  {'name' => 'job-name2', 'release' => 'release2', 'links' => {}},
                ]

                # resolve first release and template obj
                rel_ver1 = instance_double(ReleaseVersion, name: 'release1', version: '1')
                allow(deployment_plan).to receive(:release)
                                            .with('release1')
                                            .and_return(rel_ver1)

                job1 = make_job('job1', rel_ver1)
                allow(job1).to receive(:add_properties)

                expect(rel_ver1).to receive(:get_or_create_template)
                                      .with('job-name1')
                                      .and_return(job1)

                # resolve second release and template obj
                rel_ver2 = instance_double(ReleaseVersion, name: 'release2', version: '1')
                allow(deployment_plan).to receive(:release)
                                            .with('release2')
                                            .and_return(rel_ver2)

                job2 = make_job('job2', rel_ver2)
                allow(job2).to receive(:add_properties)

                expect(rel_ver2).to receive(:get_or_create_template)
                                      .with('job-name2')
                                      .and_return(job2)

                instance_group_spec['name'] = 'instance-group-name'
                parsed_instance_group
              end
            end

            context 'when one of the hashes is missing a name' do
              it 'raises an error because that is how template will be found' do
                instance_group_spec[keyword] = [{}]
                expect {
                  parsed_instance_group
                }.to raise_error(
                  ValidationMissingField,
                  "Required property 'name' was not specified in object ({})",
                )
              end
            end

            context 'when one of the elements is not a hash' do
              it 'raises an error' do
                instance_group_spec[keyword] = ['not-a-hash']
                expect {
                  parsed_instance_group
                }.to raise_error(
                  ValidationInvalidType,
                  %{Object ("not-a-hash") did not match the required type 'Hash'},
                )
              end
            end

            context 'when properties are provided in the job hash' do
              let(:job_rel_ver) do
                instance_double(
                  ReleaseVersion,
                  name: 'fake-release',
                  version: '1',
                  template: nil,
                )
              end

              before do
                instance_group_spec['templates'] = [
                  {'name' => 'job-name',
                    'links' => {'db' => 'a.b.c'},
                    'properties' => {
                      'property_1' => 'property_1_value',
                      'property_2' => {
                        'life' => 'life_value'
                      }
                    },
                  }
                ]
                instance_group_spec['release'] = 'fake-release'

                release_model = Models::Release.make(name: 'fake-release')
                release_version_model = Models::ReleaseVersion.make(version: '1', release: release_model)
                release_version_model.add_template(Models::Template.make(name: 'job-name', release: release_model))
              end

              it 'assigns those properties to the intended template' do
                allow(deployment_plan).to receive(:release)
                                            .with('fake-release')
                                            .and_return(job_rel_ver)

                job = make_job('job-name', nil)
                allow(job_rel_ver).to receive(:get_or_create_template)
                                        .with('job-name')
                                        .and_return(job)
                expect(job).to receive(:add_properties)
                                 .with({'property_1' => 'property_1_value', 'property_2' => {'life' => 'life_value'}}, 'instance-group-name')

                parsed_instance_group
              end
            end

            context 'when properties are not provided in the job hash' do
              let(:job_rel_ver) do
                instance_double(
                  ReleaseVersion,
                  name: 'fake-release-version',
                  version: '1',
                  template: nil,
                )
              end

              let (:props) do
                {
                  'smurf' => 'lazy',
                  'cat' => {
                    'color' => 'black'
                  }
                }
              end

              before do
                instance_group_spec['templates'] = [
                  {'name' => 'job-name',
                    'links' => {'db' => 'a.b.c'}
                  }
                ]

                instance_group_spec['properties'] = props
                instance_group_spec['release'] = 'fake-job-release'

                release_model = Models::Release.make(name: 'fake-release-version')
                release_version_model = Models::ReleaseVersion.make(version: '1', release: release_model)
                release_version_model.add_template(Models::Template.make(name: 'job-name', release: release_model))
              end

              it 'assigns merged global & instance group properties to the intended template' do
                allow(deployment_plan).to receive(:release)
                                            .with('fake-job-release')
                                            .and_return(job_rel_ver)

                job = make_job('fake-template-name', nil)
                allow(job_rel_ver).to receive(:get_or_create_template)
                                        .with('job-name')
                                        .and_return(job)
                expect(job).to receive(:add_properties)
                                 .with(props, 'instance-group-name')

                parsed_instance_group
              end

              context 'property mapping' do
                let(:props) do
                  {
                    'ccdb' => {
                      'user' => 'admin',
                      'password' => '12321',
                      'unused' => 'yada yada'
                    },
                    'dea' => {
                      'max_memory' => 2048
                    }
                  }
                end

                let(:mapped_props) do
                  {
                    'ccdb' => {
                      'user' => 'admin',
                      'password' => '12321',
                      'unused' => 'yada yada'
                    },
                    'dea' => {
                      'max_memory' => 2048
                    },
                    'db' => {
                      'user' => 'admin',
                      'password' => '12321',
                      'unused' => 'yada yada'
                    },
                    'mem' => 2048
                  }
                end

                it 'supports it' do
                  instance_group_spec['properties'] = props
                  instance_group_spec['property_mappings'] = {'db' => 'ccdb', 'mem' => 'dea.max_memory'}

                  instance_group_spec['release'] = 'fake-job-release'

                  allow(deployment_plan).to receive(:release)
                                              .with('fake-job-release')
                                              .and_return(job_rel_ver)

                  job = make_job('job-name', nil)
                  allow(job_rel_ver).to receive(:get_or_create_template)
                                          .with('job-name')
                                          .and_return(job)
                  expect(job).to receive(:add_properties)
                                   .with(mapped_props, 'instance-group-name')

                  parsed_instance_group
                end
              end
            end

            context 'when consumes_json and provides_json in template model have value "null"' do
              let(:job_rel_ver) do
                instance_double(
                  ReleaseVersion,
                  name: 'fake-release',
                  version: '1',
                  template: nil,
                )
              end

              before do
                instance_group_spec['templates'] = [
                  {'name' => 'job-name',
                    'links' => {'db' => 'a.b.c'},
                    'properties' => {
                      'property_1' => 'property_1_value',
                      'property_2' => {
                        'life' => 'life_value'
                      }
                    },
                  }
                ]
                instance_group_spec['release'] = 'fake-job-release'

                release_model = Models::Release.make(name: 'fake-release')
                release_version_model = Models::ReleaseVersion.make(version: '1', release: release_model)
                release_version_model.add_template(Models::Template.make(name: 'job-name', release: release_model))
              end

              it 'does not throw an error' do
                allow(deployment_plan).to receive(:release)
                                            .with('fake-job-release')
                                            .and_return(job_rel_ver)

                job = make_job('job-name', nil)
                allow(job_rel_ver).to receive(:get_or_create_template)
                                        .with('job-name')
                                        .and_return(job)
                allow(job).to receive(:add_properties)
                                .with({'property_1' => 'property_1_value', 'property_2' => {'life' => 'life_value'}}, 'instance-group-name')

                parsed_instance_group
              end
            end

            describe 'job links' do
              context 'when a job defines a provider in its release spec' do
                let(:release_1_spec) { {'provides' => [{name: 'link_1_name', type: 'link_1_type'}], 'properties' => {}}}

                before do
                  release_model_1 = Models::Release.make(name: 'release1')
                  release_version_model_1 = Models::ReleaseVersion.make(version: '1', release: release_model_1)
                  release_version_model_1.add_template(
                    Models::Template.make(
                      name: 'job-name1',
                      release: release_model_1,
                      spec: release_1_spec,
                    )
                  )

                  rel_ver1 = instance_double(ReleaseVersion, name: 'release1', version: '1')
                  allow(deployment_plan).to receive(:release)
                                              .with('release1')
                                              .and_return(rel_ver1)

                  job1 = make_job('job1', rel_ver1)
                  allow(job1).to receive(:add_properties)

                  allow(rel_ver1).to receive(:get_or_create_template)
                                        .with('job-name1')
                                        .and_return(job1)
                end

                context 'when the job exposes properties in the provided link' do
                  let(:properties_1) do
                    {
                      'street' => {'default' => 'Any Street'},
                      'scope' => {},
                      'division.router' => {'default' => 'Canada'},
                      'division.priority' => {'default' => 'NOW!'},
                      'division.sequence' => {},
                    }
                  end

                  let(:release_1_spec) do
                    {
                      'provides' => [
                        {name: 'link_1_name', type: 'link_1_type', properties: ['street', 'scope', 'division.priority', 'division.sequence']}
                      ],
                      'properties' => properties_1
                    }
                  end

                  it 'should update the provider intent metadata with the correct mapped properties' do
                    instance_group_spec[keyword] = [
                      {
                        'name' => 'job-name1',
                        'release' => 'release1',
                        'properties' => {
                          'street' => 'Any Street',
                          'division' => {
                            'priority' => 'LOW',
                            'sequence' => 'FIFO'
                          }
                        }
                      },
                    ]

                    expected_provider_params = {
                      deployment_model: deployment_plan.model,
                      instance_group_name: instance_group_spec['name'],
                      name: 'job-name1',
                      type: 'job',
                    }

                    expect(links_manager).to receive(:find_or_create_provider).with(expected_provider_params).and_return(provider)

                    expected_provider_intent_params = {
                      link_provider: provider,
                      link_original_name: 'link_1_name',
                      link_type: 'link_1_type'
                    }
                    expect(links_manager).to receive(:find_or_create_provider_intent).with(expected_provider_intent_params).and_return(provider_intent)

                    mapped_properties = {
                      'street' => 'Any Street',
                      'scope' => nil,
                      'division' => {
                        'priority' => 'LOW',
                        'sequence' => 'FIFO',
                      }
                    }

                    expect(provider_intent).to receive(:name=).with('link_1_name')
                    expect(provider_intent).to receive(:metadata=).with({:mapped_properties => mapped_properties}.to_json)
                    expect(provider_intent).to receive(:consumable=).with(true)
                    expect(provider_intent).to receive(:shared=).with(false)
                    expect(provider_intent).to receive(:save)
                    parsed_instance_group
                  end

                  context 'when it is not in the template' do
                    let(:properties_1) do
                      {
                        'street' => {'default' => 'Any Street'},
                        'division.router' => {'default' => 'Canada'},
                        'division.priority' => {'default' => 'NOW!'},
                        'division.sequence' => {},
                      }
                    end

                    it 'raise an error' do
                      instance_group_spec[keyword] = [
                        {
                          'name' => 'job-name1',
                          'release' => 'release1',
                          'properties' => {
                            'street' => 'Any Street',
                            'division' => {
                              'priority' => 'LOW',
                              'sequence' => 'FIFO'
                            }
                          }
                        },
                      ]

                      expected_provider_params = {
                        deployment_model: deployment_plan.model,
                        instance_group_name: instance_group_spec['name'],
                        name: 'job-name1',
                        type: 'job',
                      }

                      expect(links_manager).to receive(:find_or_create_provider).with(expected_provider_params).and_return(provider)
                      expect(links_manager).to_not receive(:find_or_create_provider_intent)
                      expect(provider_intent).to_not receive(:metadata=)
                      expect(provider_intent).to_not receive(:shared=)
                      expect(provider_intent).to_not receive(:name=)
                      expect(provider_intent).to_not receive(:save)

                      expect{ parsed_instance_group }.to raise_error(RuntimeError, 'Link property scope in template job-name1 is not defined in release spec')
                    end
                  end
                end

                context 'when a job does NOT define a provides section in manifest' do
                  it 'should add correct link providers and link providers intent to the DB' do
                    instance_group_spec[keyword] = [
                      {'name' => 'job-name1', 'release' => 'release1'},
                    ]

                    expected_provider_params = {
                      deployment_model: deployment_plan.model,
                      instance_group_name: instance_group_spec['name'],
                      name: 'job-name1',
                      type: 'job',
                    }

                    expect(links_manager).to receive(:find_or_create_provider).with(expected_provider_params).and_return(provider)

                    expected_provider_intent_params = {
                      link_provider: provider,
                      link_original_name: 'link_1_name',
                      link_type: 'link_1_type'
                    }
                    expect(links_manager).to receive(:find_or_create_provider_intent).with(expected_provider_intent_params).and_return(provider_intent)

                    expect(provider_intent).to receive(:name=).with('link_1_name')
                    expect(provider_intent).to receive(:metadata=).with({'mapped_properties' => {}}.to_json)
                    expect(provider_intent).to receive(:consumable=).with(true)
                    expect(provider_intent).to receive(:shared=).with(false)
                    expect(provider_intent).to receive(:save)
                    parsed_instance_group
                  end
                end

                context 'when a job defines a provides section in manifest' do
                  before do
                    instance_group_spec[keyword] = [
                      {
                       'name' => 'job-name1',
                       'release' => 'release1',
                       'provides' => {
                         'link_1_name' => {
                           'as' => 'link_1_name_alias',
                           'shared' => true,
                         }
                       }
                      }
                    ]
                  end

                  it 'should add correct link providers and link providers intent to the DB' do
                    expected_provider_params = {
                      deployment_model: deployment_plan.model,
                      instance_group_name: instance_group_spec['name'],
                      name: 'job-name1',
                      type: 'job',
                    }

                    expect(links_manager).to receive(:find_or_create_provider).with(expected_provider_params).and_return(provider)

                    expected_provider_intent_params = {
                      link_provider: provider,
                      link_original_name: 'link_1_name',
                      link_type: 'link_1_type'
                    }
                    expect(links_manager).to receive(:find_or_create_provider_intent).with(expected_provider_intent_params).and_return(provider_intent)

                    expect(provider_intent).to receive(:name=).with('link_1_name_alias')
                    expect(provider_intent).to receive(:metadata=).with({'mapped_properties' => {}}.to_json)
                    expect(provider_intent).to receive(:consumable=).with(true)
                    expect(provider_intent).to receive(:shared=).with(true)
                    expect(provider_intent).to receive(:save)
                    parsed_instance_group
                  end
                end

                context 'when a job defines a nil provides section in the manifest' do
                  before do
                    instance_group_spec[keyword] = [
                      {
                        'name' => 'job-name1',
                        'release' => 'release1',
                        'provides' => {
                          'link_1_name' => 'nil'
                        }
                      }
                    ]
                  end

                  it 'should set the intent consumable to false' do
                    expected_provider_params = {
                      deployment_model: deployment_plan.model,
                      instance_group_name: instance_group_spec['name'],
                      name: 'job-name1',
                      type: 'job',
                    }
                    expect(links_manager).to receive(:find_or_create_provider).with(expected_provider_params).and_return(provider)

                    expected_provider_intent_params = {
                      link_provider: provider,
                      link_original_name: 'link_1_name',
                      link_type: 'link_1_type'
                    }
                    expect(links_manager).to receive(:find_or_create_provider_intent).with(expected_provider_intent_params).and_return(provider_intent)

                    expect(provider_intent).to receive(:name=).with('link_1_name')
                    expect(provider_intent).to receive(:metadata=).with({'mapped_properties' => {}}.to_json)
                    expect(provider_intent).to receive(:consumable=).with(false)
                    expect(provider_intent).to receive(:shared=).with(false)
                    expect(provider_intent).to receive(:save)
                    parsed_instance_group
                  end
                end

                context 'provider validation' do
                  before do
                    expect(links_manager).to receive(:find_or_create_provider)
                    expect(links_manager).to_not receive(:find_or_create_provider_intent)
                  end

                  context 'when a manifest job explicitly defines name or type for a provider' do
                    it 'should fail if there is a name' do
                      instance_group_spec[keyword] = [
                        {
                          'name' => 'job-name1',
                          'release' => 'release1',
                          'provides' => {
                            'link_1_name' => {
                              'name' => 'better_link_1_name',
                              'shared' => true,
                            }
                          }
                        }
                      ]

                      expect {
                        parsed_instance_group
                      }.to raise_error(RuntimeError, "Cannot specify 'name' or 'type' properties in the manifest for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'. Please provide these keys in the release only.")
                    end

                    it 'should fail if there is a type' do
                      instance_group_spec[keyword] = [
                        {
                          'name' => 'job-name1',
                          'release' => 'release1',
                          'provides' => {
                            'link_1_name' => {
                              'type' => 'better_link_1_type',
                              'shared' => true,
                            }
                          }
                        }
                      ]

                      expect {
                        parsed_instance_group
                      }.to raise_error(RuntimeError, "Cannot specify 'name' or 'type' properties in the manifest for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'. Please provide these keys in the release only.")
                    end
                  end

                  context 'when the provides section is not a hash' do
                    it "raise an error" do
                      instance_group_spec[keyword] = [
                        {
                          'name' => 'job-name1',
                          'release' => 'release1',
                          'provides' => {
                            'link_1_name' => ['invalid stuff']
                          }
                        }
                      ]

                      expect {
                        parsed_instance_group
                      }.to raise_error(RuntimeError, "Provider 'link_1_name' in job 'job-name1' in instance group 'instance-group-name' specified in the manifest should only be a hash or string 'nil'")
                    end

                    context "when it is a string that is not 'nil'" do
                      it "raise an error" do
                        instance_group_spec[keyword] = [
                          {
                            'name' => 'job-name1',
                            'release' => 'release1',
                            'provides' => {
                              'link_1_name' => 'invalid stuff'
                            }
                          }
                        ]

                        expect {
                          parsed_instance_group
                        }.to raise_error(RuntimeError, "Provider 'link_1_name' in job 'job-name1' in instance group 'instance-group-name' specified in the manifest should only be a hash or string 'nil'")
                      end
                    end
                  end
                end

                context 'when a manifest job defines a provider which is not specified in the release' do
                  it 'should fail because it does not match the release' do
                    instance_group_spec[keyword] = [
                      {
                        'name' => 'job-name1',
                        'release' => 'release1',
                        'provides' => {
                          'new_link_name' => {
                            'shared' => 'false',
                          }
                        }
                      }
                    ]

                    expect(links_manager).to receive(:find_or_create_provider).and_return(provider)

                    expect(links_manager).to receive(:find_or_create_provider_intent).and_return(provider_intent)

                    expect(provider_intent).to receive(:name=).with('link_1_name')
                    expect(provider_intent).to receive(:consumable=).with(true)
                    expect(provider_intent).to receive(:metadata=).with({'mapped_properties' => {}}.to_json)
                    expect(provider_intent).to receive(:shared=).with(false)
                    expect(provider_intent).to receive(:save)
                    expect {  parsed_instance_group }.to raise_error(RuntimeError, "Manifest defines unknown providers:\n  - Job 'job-name1' does not provide link 'new_link_name' in the release spec")
                  end
                end
              end

              context 'when the job does NOT define any provider in its release spec' do
                before do
                  release_model_1 = Models::Release.make(name: 'release1')
                  release_version_model_1 = Models::ReleaseVersion.make(version: '1', release: release_model_1)
                  release_1_spec = {'consumes' => [{name: 'link_1_name', type: 'link_1_type'}], 'properties' => {}}
                  release_version_model_1.add_template(
                    Models::Template.make(
                      name: 'job-name1',
                      release: release_model_1,
                      spec: release_1_spec,
                      )
                  )

                  rel_ver1 = instance_double(ReleaseVersion, name: 'release1', version: '1')
                  allow(deployment_plan).to receive(:release)
                                              .with('release1')
                                              .and_return(rel_ver1)

                  job1 = make_job('job1', rel_ver1)
                  allow(job1).to receive(:add_properties)

                  allow(rel_ver1).to receive(:get_or_create_template)
                                       .with('job-name1')
                                       .and_return(job1)

                  allow(links_manager).to receive(:find_or_create_provider_intent).and_return(provider_intent)
                end

                context 'when the manifest specifies provided links for that job' do
                  it 'raise an error' do
                    instance_group_spec[keyword] = [
                      {
                        'name' => 'job-name1',
                        'release' => 'release1',
                        'provides' => {
                          'link_1_name' => {
                            'as' => 'my_link',
                            'shared' => false,
                          }
                        }
                      }
                    ]

                    expect(links_manager).to_not receive(:find_or_create_provider)
                    expect(links_manager).to_not receive(:find_or_create_provider_intent)
                    expect {
                      parsed_instance_group
                    }.to raise_error(RuntimeError, "Job 'job-name1' in instance group 'instance-group-name' specifies providers in the manifest but the job does not define any providers in the release spec")
                  end
                end
              end

              context 'when a job defines a consumer in its release spec' do

                context 'when consumer is implicit (not specified in the deployment manifest)' do
                  let(:release_1_spec) { {'consumes' => [{name: 'link_1_name', type: 'link_1_type'}]}}

                  before do
                    release_model_1 = Models::Release.make(name: 'release1')
                    release_version_model_1 = Models::ReleaseVersion.make(version: '1', release: release_model_1)
                    release_version_model_1.add_template(
                      Models::Template.make(
                        name: 'job-name1',
                        release: release_model_1,
                        spec: release_1_spec
                      )
                    )

                    rel_ver1 = instance_double(ReleaseVersion, name: 'release1', version: '1')
                    allow(deployment_plan).to receive(:release)
                                                .with('release1')
                                                .and_return(rel_ver1)

                    job1 = make_job('job1', rel_ver1)
                    allow(job1).to receive(:add_properties)

                    allow(rel_ver1).to receive(:get_or_create_template)
                                         .with('job-name1')
                                         .and_return(job1)

                    instance_group_spec[keyword] = [
                      {
                        'name' => 'job-name1',
                        'release' => 'release1'
                      },
                    ]
                  end


                  it 'should add the consumer and consumer intent to the DB' do
                    expected_consumer_params = {
                      deployment_model: deployment_plan.model,
                      instance_group_name: instance_group_spec['name'],
                      name: 'job-name1',
                      type: 'job',
                    }

                    expect(links_manager).to receive(:find_or_create_consumer).with(expected_consumer_params).and_return(consumer)

                    expected_consumer_intent_params = {
                      link_consumer: consumer,
                      link_original_name: 'link_1_name',
                      link_type: 'link_1_type'
                    }

                    expect(links_manager).to receive(:find_or_create_consumer_intent).with(expected_consumer_intent_params).and_return(consumer_intent)

                    expect(consumer_intent).to receive(:name=).with('link_1_name')
                    expect(consumer_intent).to receive(:blocked=).with(false)
                    expect(consumer_intent).to receive(:optional=).with(false)
                    expect(consumer_intent).to receive(:metadata=).with({:explicit_link => false}.to_json)
                    expect(consumer_intent).to receive(:save)
                    parsed_instance_group
                  end

                  context 'when the release spec defines the link as optional' do
                    let(:release_1_spec) { {'consumes' => [{name: 'link_1_name', type: 'link_1_type', optional: true}]}}

                    it 'sets consumer intent optional field to true' do
                      expect(links_manager).to receive(:find_or_create_consumer).and_return(consumer)
                      expect(links_manager).to receive(:find_or_create_consumer_intent).and_return(consumer_intent)

                      expect(consumer_intent).to receive(:metadata=).with({:explicit_link => false}.to_json)
                      expect(consumer_intent).to receive(:name=).with('link_1_name')
                      expect(consumer_intent).to receive(:blocked=).with(false)
                      expect(consumer_intent).to receive(:optional=).with(true)
                      expect(consumer_intent).to receive(:save)
                      parsed_instance_group
                    end
                  end
                end

                context 'when consumer is explicit (specified in the deployment manifest)' do
                  let(:release_1_spec) { {'consumes' => [{name: 'link_1_name', type: 'link_1_type'}]}}
                  let(:consumer_options) { { 'from' => 'snoopy'} }
                  let(:manifest_link_consumers) { {'link_1_name' => consumer_options} }

                  before do
                    release_model_1 = Models::Release.make(name: 'release1')
                    release_version_model_1 = Models::ReleaseVersion.make(version: '1', release: release_model_1)
                    release_version_model_1.add_template(
                      Models::Template.make(
                        name: 'job-name1',
                        release: release_model_1,
                        spec: release_1_spec
                      )
                    )

                    rel_ver1 = instance_double(ReleaseVersion, name: 'release1', version: '1')
                    allow(deployment_plan).to receive(:release)
                                                .with('release1')
                                                .and_return(rel_ver1)

                    job1 = make_job('job1', rel_ver1)
                    allow(job1).to receive(:add_properties)

                    allow(rel_ver1).to receive(:get_or_create_template)
                                         .with('job-name1')
                                         .and_return(job1)

                    instance_group_spec[keyword] = [
                      {
                        'name' => 'job-name1',
                        'release' => 'release1',
                        'consumes' => manifest_link_consumers
                      },
                    ]
                  end

                  it 'should add the consumer and consumer intent to the DB' do
                    expected_consumer_params = {
                      deployment_model: deployment_plan.model,
                      instance_group_name: instance_group_spec['name'],
                      name: 'job-name1',
                      type: 'job',
                    }

                    expect(links_manager).to receive(:find_or_create_consumer).with(expected_consumer_params).and_return(consumer)

                    expected_consumer_intent_params = {
                      link_consumer: consumer,
                      link_original_name: 'link_1_name',
                      link_type: 'link_1_type'
                    }

                    expect(links_manager).to receive(:find_or_create_consumer_intent).with(expected_consumer_intent_params).and_return(consumer_intent)

                    expect(consumer_intent).to receive(:name=).with('snoopy')
                    expect(consumer_intent).to receive(:blocked=).with(false)
                    expect(consumer_intent).to receive(:metadata=).with({:explicit_link => true}.to_json)
                    expect(consumer_intent).to receive(:optional=).with(false)
                    expect(consumer_intent).to receive(:save)
                    parsed_instance_group
                  end

                  context 'when the consumer is explicitly set to nil' do
                    let(:consumer_options) { "nil" }

                    before do
                      allow(consumer_intent).to receive(:name=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:metadata=)
                      allow(consumer_intent).to receive(:save)
                    end

                    it 'should set the consumer intent blocked' do
                      expect(consumer_intent).to receive(:blocked=).with(true)

                      parsed_instance_group
                    end
                  end

                  #TODO LINKS: Move the it block out as the base case.
                  context 'when the consumer does not have a from key' do
                    let(:consumer_options) { {} }

                    before do
                      allow(consumer_intent).to receive(:blocked=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:metadata=)
                      allow(consumer_intent).to receive(:save)
                    end

                    it 'should set the consumer intent name to original name' do
                      expect(consumer_intent).to receive(:name=).with('link_1_name')

                      parsed_instance_group
                    end
                  end

                  context 'when the consumer specifies a specific network' do
                    let(:consumer_options) { { 'network' => 'charlie'} }

                    before do
                      allow(consumer_intent).to receive(:name=)
                      allow(consumer_intent).to receive(:blocked=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:save)
                    end

                    it 'will add specified network name to the metadata' do
                      allow(consumer_intent).to receive(:metadata=).with({explicit_link: true, network: 'charlie'}.to_json)
                      parsed_instance_group
                    end
                  end

                  context 'when the consumer specifies to use ip addresses only' do
                    let(:consumer_options) { { 'ip_addresses' => true} }

                    before do
                      allow(consumer_intent).to receive(:name=)
                      allow(consumer_intent).to receive(:blocked=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:save)
                    end

                    it 'will set the ip_addresses flag in the metadata to true' do
                      allow(consumer_intent).to receive(:metadata=).with({explicit_link: true, ip_addresses: true}.to_json)
                      parsed_instance_group
                    end
                  end

                  context 'when the consumer specifies to use a deployment' do
                    let(:consumer_options) { { 'deployment' => 'some-other-deployment' } }

                    before do
                      allow(consumer_intent).to receive(:name=)
                      allow(consumer_intent).to receive(:blocked=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:save)
                    end

                    context 'when the provider deployment exists' do
                      before do
                        Models::Deployment.make(name: 'some-other-deployment')
                      end

                      it 'will set the from_deployment flag in the metadata to the provider deployment name' do
                        allow(consumer_intent).to receive(:metadata=).with({explicit_link: true, from_deployment: 'some-other-deployment'}.to_json)
                        parsed_instance_group
                      end
                    end

                    context 'when the provider deployment exists' do
                      it 'raise an error' do
                        expect {
                          parsed_instance_group
                        }.to raise_error "Link 'link_1_name' in job 'job-name1' from instance group 'instance-group-name' consumes from deployment 'some-other-deployment', but the deployment does not exist."
                      end
                    end
                  end

                  context 'when the consumer specifies the name key in the consumes section of the manifest' do
                    let(:consumer_options) { { 'name' => 'i should not be here'} }

                    before do
                      allow(consumer_intent).to receive(:name=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:save)
                      allow(consumer_intent).to receive(:metadata=)
                    end

                    it 'raise an error' do
                      expect {parsed_instance_group}.to raise_error "Cannot specify 'name' or 'type' properties in the manifest for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'. Please provide these keys in the release only."
                    end
                  end

                  context 'when the consumer specifies the type key in the consumes section of the manifest' do
                    let(:consumer_options) { { 'type' => 'i should not be here'} }

                    before do
                      allow(consumer_intent).to receive(:name=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:save)
                      allow(consumer_intent).to receive(:metadata=)
                    end

                    it 'raise an error' do
                      expect {parsed_instance_group}.to raise_error "Cannot specify 'name' or 'type' properties in the manifest for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'. Please provide these keys in the release only."
                    end
                  end

                  context 'when processing manual links' do
                    let(:manual_provider) { instance_double(Bosh::Director::Models::Links::LinkProvider) }
                    let(:manual_provider_intent) { instance_double(Bosh::Director::Models::Links::LinkProviderIntent) }
                    let(:consumer_options) do
                      {
                        'instances' => 'instances definition',
                        'properties' => 'property definitions',
                        'address' => 'address definition'
                      }
                    end

                    before do
                      allow(deployment_model).to receive(:name).and_return('charlie')

                      allow(consumer_intent).to receive(:name=)
                      allow(consumer_intent).to receive(:blocked=)
                      allow(consumer_intent).to receive(:optional=)
                      allow(consumer_intent).to receive(:metadata=)
                      allow(consumer_intent).to receive(:save)

                      allow(consumer_intent).to receive(:original_name).and_return('link_1_name')
                      allow(consumer_intent).to receive(:type).and_return('link_1_type')

                      allow(consumer).to receive(:deployment).and_return(deployment_model)
                      allow(consumer).to receive(:instance_group).and_return('consumer_instance_group')
                      allow(consumer).to receive(:name).and_return('consumer_name')

                      allow(manual_provider_intent).to receive(:content=)
                      allow(manual_provider_intent).to receive(:name=)
                      expect(manual_provider_intent).to receive(:save)
                    end

                    it 'adds manual_link flag as true to the consumer intents metadata' do
                      allow(links_manager).to receive(:find_or_create_provider_intent).and_return(manual_provider_intent)

                      expect(consumer_intent).to receive(:metadata=).with({explicit_link: true, manual_link: true}.to_json)

                      parsed_instance_group
                    end

                    it 'creates a manual provider in the database' do
                      allow(links_manager).to receive(:find_or_create_provider_intent).and_return(manual_provider_intent)

                      expect(links_manager).to receive(:find_or_create_provider).with(
                        deployment_model: deployment_model,
                        instance_group_name: 'consumer_instance_group',
                        name: 'consumer_name',
                        type: 'manual'
                      ).and_return(manual_provider)

                      parsed_instance_group
                    end

                    it 'creates a manual provider intent in the database' do
                      allow(links_manager).to receive(:find_or_create_provider).and_return(manual_provider)

                      expect(links_manager).to receive(:find_or_create_provider_intent).with(
                        link_provider: manual_provider,
                        link_original_name: 'link_1_name',
                        link_type: 'link_1_type'
                      ).and_return(manual_provider_intent)

                      expected_content = {
                        'instances' => 'instances definition',
                        'properties' => 'property definitions',
                        'address' => 'address definition',
                        'deployment_name' => 'charlie'
                      }

                      expect(manual_provider_intent).to receive(:name=).with('link_1_name')
                      expect(manual_provider_intent).to receive(:content=).with(expected_content.to_json)

                      parsed_instance_group
                    end

                    context 'when the manual link has keys that are not whitelisted' do
                      let(:consumer_options) do
                        {
                          'instances' => 'instances definition',
                          'properties' => 'property definitions',
                          'address' => 'address definition',
                          'foo' => 'bar',
                          'baz' => 'boo'
                        }
                      end

                      it 'should only add whitelisted values' do
                        allow(links_manager).to receive(:find_or_create_provider).and_return(manual_provider)

                        expect(links_manager).to receive(:find_or_create_provider_intent).with(
                          link_provider: manual_provider,
                          link_original_name: 'link_1_name',
                          link_type: 'link_1_type'
                        ).and_return(manual_provider_intent)

                        expected_content = {
                          'instances' => 'instances definition',
                          'properties' => 'property definitions',
                          'address' => 'address definition',
                          'deployment_name' => 'charlie'
                        }

                        expect(manual_provider_intent).to receive(:content=).with(expected_content.to_json)

                        parsed_instance_group
                      end
                    end
                  end

                  context 'consumer validation' do
                    context "when 'instances' and 'from' keywords are specified at the same time" do
                      let(:consumer_options) { { 'from' => 'snoopy', 'instances' => ['1.2.3.4']} }

                      it 'should raise an error' do
                        expect{
                          parsed_instance_group
                        }.to raise_error(/Cannot specify both 'instances' and 'from' keys for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'./)
                      end
                    end

                    context "when 'properties' and 'from' keywords are specified at the same time" do
                      let(:consumer_options) { { 'from' => 'snoopy', 'properties' => {'meow' => 'cat'}} }

                      it 'should raise an error' do
                        expect{
                          parsed_instance_group
                        }.to raise_error(/Cannot specify both 'properties' and 'from' keys for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'./)
                      end
                    end

                    context "when 'properties' is defined but 'instances' is not" do
                      let(:consumer_options) { { 'properties' => 'snoopy'} }

                      it 'should raise an error' do
                        expect{
                          parsed_instance_group
                        }.to raise_error(/Cannot specify 'properties' without 'instances' for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'./)
                      end
                    end

                    context "when 'ip_addresses' value is not a boolean" do
                      let(:consumer_options) { { 'ip_addresses' => 'not a boolean'} }

                      it 'should raise an error' do
                        expect{
                          parsed_instance_group
                        }.to raise_error(/Cannot specify non boolean values for 'ip_addresses' field for link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name'./)
                      end
                    end

                    context 'when the manifest specifies consumers that are not defined in the release spec' do
                      before do
                        allow(consumer_intent).to receive(:name=)
                        allow(consumer_intent).to receive(:blocked=)
                        allow(consumer_intent).to receive(:optional=)
                        allow(consumer_intent).to receive(:metadata=)
                        allow(consumer_intent).to receive(:save)

                        manifest_link_consumers['first_undefined'] = {}
                        manifest_link_consumers['second_undefined'] = {}
                      end

                      it 'should raise an error for each undefined consumer' do
                        expected_error = [
                          'Manifest defines unknown consumers:',
                          " - Job 'job-name1' does not define consumer 'first_undefined' in the release spec",
                          " - Job 'job-name1' does not define consumer 'second_undefined' in the release spec"
                        ].join("\n")

                        expect{
                          parsed_instance_group
                        }.to raise_error(expected_error)
                      end
                    end

                    context 'when the manifest specifies consumers that are not hashes or "nil" string' do
                      context 'consumer is an array' do
                        let(:consumer_options) { ['Unaccepted type array'] }

                        it 'should raise an error' do
                          expect{
                            parsed_instance_group
                          }.to raise_error "Link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name' specified in the manifest should only be a hash or string 'nil'"
                        end
                      end

                      context 'consumer is a string that is not "nil"' do
                        let(:consumer_options) { 'Unaccepted string value' }

                        it 'should raise an error' do
                          expect{
                            parsed_instance_group
                          }.to raise_error "Link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name' specified in the manifest should only be a hash or string 'nil'"
                        end
                      end

                      context 'consumer is empty or set to null' do
                        let(:consumer_options) { nil }

                        it 'should raise an error' do
                          expect{
                            parsed_instance_group
                          }.to raise_error "Link 'link_1_name' in job 'job-name1' in instance group 'instance-group-name' specified in the manifest should only be a hash or string 'nil'"
                        end
                      end
                    end
                  end
                end
              end

              context 'when the job does NOT define any consumer in its release spec' do
                before do
                  release_model_1 = Models::Release.make(name: 'release1')
                  release_version_model_1 = Models::ReleaseVersion.make(version: '1', release: release_model_1)
                  release_1_spec = {'properties' => {}}
                  release_version_model_1.add_template(
                    Models::Template.make(
                      name: 'job-name1',
                      release: release_model_1,
                      spec: release_1_spec,
                      )
                  )

                  rel_ver1 = instance_double(ReleaseVersion, name: 'release1', version: '1')
                  allow(deployment_plan).to receive(:release)
                                              .with('release1')
                                              .and_return(rel_ver1)

                  job1 = make_job('job1', rel_ver1)
                  allow(job1).to receive(:add_properties)

                  allow(rel_ver1).to receive(:get_or_create_template)
                                       .with('job-name1')
                                       .and_return(job1)

                  allow(links_manager).to receive(:find_or_create_provider_intent).and_return(provider_intent)
                end

                it 'should raise an error when the manifest has consumer specified' do
                  instance_group_spec[keyword] = [
                    {
                      'name' => 'job-name1',
                      'release' => 'release1',
                      'consumes' => {
                        'undefined_link_consumer' => {}
                      }
                    }
                  ]

                  expect {
                    parsed_instance_group
                  }.to raise_error("Job 'job-name1' in instance group 'instance-group-name' specifies consumers in the manifest but the job does not define any consumers in the release spec")
                end
              end

              context 'when a job does NOT define any providers or consumers and it does not specify any in the manfest' do
                before do
                  release_model_1 = Models::Release.make(name: 'release1')
                  release_version_model_1 = Models::ReleaseVersion.make(version: '1', release: release_model_1)
                  release_1_spec = {'properties' => {}}
                  release_version_model_1.add_template(
                    Models::Template.make(
                      name: 'job-name1',
                      release: release_model_1,
                      spec: release_1_spec,
                      )
                  )

                  rel_ver1 = instance_double(ReleaseVersion, name: 'release1', version: '1')
                  allow(deployment_plan).to receive(:release)
                                              .with('release1')
                                              .and_return(rel_ver1)

                  job1 = make_job('job1', rel_ver1)
                  allow(job1).to receive(:add_properties)

                  allow(rel_ver1).to receive(:get_or_create_template)
                                       .with('job-name1')
                                       .and_return(job1)

                  instance_group_spec[keyword] = [
                    {
                      'name' => 'job-name1',
                      'release' => 'release1',
                    }
                  ]
                end

                it 'does not create any providers or consumers' do
                  expect(links_manager).to_not receive(:find_or_create_provider)
                  expect(links_manager).to_not receive(:find_or_create_consumer)
                  expect(links_manager).to_not receive(:find_or_create_provider_intent)
                  expect(links_manager).to_not receive(:find_or_create_consumer_intent)
                  parsed_instance_group
                end
              end
            end
          end

          context 'when value is not an array' do
            it 'raises an error' do
              instance_group_spec[keyword] = 'not-an-array'
              expect {
                parsed_instance_group
              }.to raise_error(
                ValidationInvalidType,
                %{Property '#{keyword}' value ("not-an-array") did not match the required type 'Array'},
              )
            end
          end
        end

        describe 'templates key' do
          let(:keyword) { 'templates' }
          it_behaves_like 'templates/jobs key'
        end

        describe 'jobs key' do
          let(:keyword) { 'jobs' }
          it_behaves_like 'templates/jobs key'
        end

        describe 'validating job templates' do
          context 'when both template and templates are specified' do
            before do
              instance_group_spec['templates'] = []
              instance_group_spec['template'] = []
            end

            it 'raises' do
              expect { parsed_instance_group }.to raise_error(
                InstanceGroupInvalidTemplates,
                "Instance group 'instance-group-name' specifies both template and templates keys, only one is allowed"
              )
            end
          end

          context 'when both jobs and templates are specified' do
            before do
              instance_group_spec['templates'] = []
              instance_group_spec['jobs'] = []
            end

            it 'raises' do
              expect { parsed_instance_group }.to raise_error(
                InstanceGroupInvalidTemplates,
                "Instance group 'instance-group-name' specifies both templates and jobs keys, only one is allowed"
              )
            end
          end

          context 'when neither key is specified' do
            before do
              instance_group_spec.delete('templates')
              instance_group_spec.delete(Job)
              instance_group_spec.delete('jobs')
            end

            it 'raises' do
              expect { parsed_instance_group }.to raise_error(
                ValidationMissingField,
                "Instance group 'instance-group-name' does not specify jobs key"
              )
            end
          end
        end

        describe 'persistent_disk key' do
          it 'parses persistent disk if present' do
            instance_group_spec['persistent_disk'] = 300

            expect(
              parsed_instance_group.persistent_disk_collection.generate_spec['persistent_disk']
            ).to eq 300
          end

          it 'does not add a persistent disk if the size is 0' do
            instance_group_spec['persistent_disk'] = 0

            expect(
              parsed_instance_group.persistent_disk_collection.collection
            ).to be_empty
          end

          it 'allows persistent disk to be nil' do
            instance_group_spec.delete('persistent_disk')

            expect(
              parsed_instance_group.persistent_disk_collection.generate_spec['persistent_disk']
            ).to eq 0
          end

          it 'raises an error if the disk size is less than zero' do
            instance_group_spec['persistent_disk'] = -300
            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupInvalidPersistentDisk,
              "Instance group 'instance-group-name' references an invalid persistent disk size '-300'"
            )
          end
        end

        describe 'persistent_disk_type key' do
          it 'parses persistent_disk_type' do
            instance_group_spec['persistent_disk_type'] = 'fake-disk-pool-name'
            expect(deployment_plan).to receive(:disk_type)
                                         .with('fake-disk-pool-name')
                                         .and_return(disk_type)

            expect(disk_collection).to receive(:add_by_disk_type).with(disk_type)

            parsed_instance_group
          end

          it 'complains about unknown disk type' do
            instance_group_spec['persistent_disk_type'] = 'unknown-disk-pool'
            expect(deployment_plan).to receive(:disk_type)
                                         .with('unknown-disk-pool')
                                         .and_return(nil)

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupUnknownDiskType,
              "Instance group 'instance-group-name' references an unknown disk type 'unknown-disk-pool'"
            )
          end
        end

        describe 'persistent_disk_pool key' do
          it 'parses persistent_disk_pool' do
            instance_group_spec['persistent_disk_pool'] = 'fake-disk-pool-name'
            expect(deployment_plan).to receive(:disk_type)
                                         .with('fake-disk-pool-name')
                                         .and_return(disk_type)

            expect(PersistentDiskCollection).to receive_message_chain(:new, :add_by_disk_type).with(disk_type)

            parsed_instance_group
          end

          it 'complains about unknown disk pool' do
            instance_group_spec['persistent_disk_pool'] = 'unknown-disk-pool'
            expect(deployment_plan).to receive(:disk_type)
                                         .with('unknown-disk-pool')
                                         .and_return(nil)

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupUnknownDiskType,
              "Instance group 'instance-group-name' references an unknown disk pool 'unknown-disk-pool'"
            )
          end
        end

        describe 'persistent_disks' do
          let(:disk_type_small) { instance_double(DiskType) }
          let(:disk_type_large) { instance_double(DiskType) }
          let(:disk_collection) { instance_double(PersistentDiskCollection) }

          context 'when persistent disks are well formatted' do
            before do
              instance_group_spec['persistent_disks'] = [{'name' => 'my-disk', 'type' => 'disk-type-small'},
                                                         {'name' => 'my-favourite-disk', 'type' => 'disk-type-large'}]
              expect(deployment_plan).to receive(:disk_type)
                                           .with('disk-type-small')
                                           .and_return(disk_type_small)
              expect(deployment_plan).to receive(:disk_type)
                                           .with('disk-type-large')
                                           .and_return(disk_type_large)
              expect(disk_collection).to receive(:add_by_disk_name_and_type)
                                           .with('my-favourite-disk', disk_type_large)
              expect(disk_collection).to receive(:add_by_disk_name_and_type)
                                           .with('my-disk', disk_type_small)
            end

            it 'parses successfully' do
              expect(provider_intent).to receive(:shared=).twice
              expect(provider_intent).to receive(:name=).with('my-disk')
              expect(provider_intent).to receive(:name=).with('my-favourite-disk')
              expect(provider_intent).to receive(:content=).twice
              expect(provider_intent).to receive(:save).twice
              #  expect not to raise an error
              parsed_instance_group
            end

            it 'adds a link provider for each persistent disk' do
              expected_provider_params = {
                deployment_model: deployment_plan.model,
                instance_group_name: instance_group_spec['name'],
                name: instance_group_spec['name'],
                type: 'disk',
              }

              expect(links_manager).to receive(:find_or_create_provider).with(expected_provider_params)

              expect(provider_intent).to receive(:shared=).twice
              expect(provider_intent).to receive(:name=).with('my-disk')
              expect(provider_intent).to receive(:name=).with('my-favourite-disk')
              expect(provider_intent).to receive(:content=).twice
              expect(provider_intent).to receive(:save).twice
              parsed_instance_group
            end

            it 'adds a link provider intent for each persistent disk' do
              local_link_provider = instance_double(Bosh::Director::Models::Links::LinkProvider)
              disk_1_provider_intent = instance_double(Bosh::Director::Models::Links::LinkProviderIntent)
              disk_2_provider_intent = instance_double(Bosh::Director::Models::Links::LinkProviderIntent)
              disk_1_link = instance_double(Bosh::Director::DeploymentPlan::DiskLink)
              disk_2_link = instance_double(Bosh::Director::DeploymentPlan::DiskLink)

              expected_provider_params = {
                deployment_model: deployment_plan.model,
                instance_group_name: instance_group_spec['name'],
                name: instance_group_spec['name'],
                type: 'disk',
              }
              expect(links_manager).to receive(:find_or_create_provider).with(expected_provider_params).twice.and_return(local_link_provider)

              # Disk 1
              expected_provider_intent_params = {
                link_provider: local_link_provider,
                link_original_name: 'my-disk',
                link_type: 'disk',
              }

              expect(links_manager).to receive(:find_or_create_provider_intent).with(expected_provider_intent_params).and_return(disk_1_provider_intent)
              expect(disk_1_provider_intent).to receive(:shared=).with(false)
              expect(disk_1_provider_intent).to receive(:name=).with('my-disk')
              expect(Bosh::Director::DeploymentPlan::DiskLink).to receive(:new).and_return(disk_1_link)
              expect(disk_1_link).to receive(:spec).and_return({'hello'=> 'hello1'})
              expect(disk_1_provider_intent).to receive(:content=).with({'hello'=> 'hello1'}.to_json)
              expect(disk_1_provider_intent).to receive(:save)

              # Disk 2
              expected_provider_intent_params2 = {
                link_provider: local_link_provider,
                link_original_name: 'my-favourite-disk',
                link_type: 'disk',
              }

              expect(links_manager).to receive(:find_or_create_provider_intent).with(expected_provider_intent_params2).and_return(disk_2_provider_intent)
              expect(disk_2_provider_intent).to receive(:shared=).with(false)
              expect(disk_2_provider_intent).to receive(:name=).with('my-favourite-disk')
              expect(Bosh::Director::DeploymentPlan::DiskLink).to receive(:new).and_return(disk_2_link)
              expect(disk_2_link).to receive(:spec).and_return({'hello'=> 'hello2'})
              expect(disk_2_provider_intent).to receive(:content=).with({'hello'=> 'hello2'}.to_json)
              expect(disk_2_provider_intent).to receive(:save)

              parsed_instance_group
            end
          end

          context 'when persistent disks are NOT well formatted' do
            it 'complains about empty names' do
              instance_group_spec['persistent_disks'] = [{'name' => '', 'type' => 'disk-type-small'}]
              expect {
                parsed_instance_group
              }.to raise_error InstanceGroupInvalidPersistentDisk,
                               "Instance group 'instance-group-name' persistent_disks's section contains a disk with no name"
            end

            it 'complains about two disks with the same name' do
              instance_group_spec['persistent_disks'] = [
                {'name' => 'same', 'type' => 'disk-type-small'},
                {'name' => 'same', 'type' => 'disk-type-small'}
              ]

              expect {
                parsed_instance_group
              }.to raise_error InstanceGroupInvalidPersistentDisk,
                               "Instance group 'instance-group-name' persistent_disks's section contains duplicate names"
            end

            it 'complains about unknown disk type' do
              instance_group_spec['persistent_disks'] = [{'name' => 'disk-name-0', 'type' => 'disk-type-small'}]
              expect(deployment_plan).to receive(:disk_type)
                                           .with('disk-type-small')
                                           .and_return(nil)

              expect {
                parsed_instance_group
              }.to raise_error(
                     InstanceGroupUnknownDiskType,
                     "Instance group 'instance-group-name' persistent_disks's section references an unknown disk type 'disk-type-small'"
                   )
            end
          end
        end

        context 'when job has multiple persistent_disks keys' do
          it 'raises an error if persistent_disk and persistent_disk_pool are both present' do
            instance_group_spec['persistent_disk'] = 300
            instance_group_spec['persistent_disk_pool'] = 'fake-disk-pool-name'

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupInvalidPersistentDisk,
              "Instance group 'instance-group-name' specifies more than one of the following keys: 'persistent_disk', 'persistent_disk_type', 'persistent_disk_pool' and 'persistent_disks'. Choose one."
            )
          end

          it 'raises an error if persistent_disk and persistent_disk_type are both present' do
            instance_group_spec['persistent_disk'] = 300
            instance_group_spec['persistent_disk_type'] = 'fake-disk-pool-name'

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupInvalidPersistentDisk,
              "Instance group 'instance-group-name' specifies more than one of the following keys: 'persistent_disk', 'persistent_disk_type', 'persistent_disk_pool' and 'persistent_disks'. Choose one."
            )
          end

          it 'raises an error if persistent_disk_type and persistent_disk_pool are both present' do
            instance_group_spec['persistent_disk_type'] = 'fake-disk-pool-name'
            instance_group_spec['persistent_disk_pool'] = 'fake-disk-pool-name'

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupInvalidPersistentDisk,
              "Instance group 'instance-group-name' specifies more than one of the following keys: 'persistent_disk', 'persistent_disk_type', 'persistent_disk_pool' and 'persistent_disks'. Choose one."
            )
          end
        end

        describe 'resource_pool key' do
          it 'parses resource pool' do
            expect(deployment_plan).to receive(:resource_pool)
                                         .with('fake-resource-pool-name')
                                         .and_return(resource_pool)

            instance_group = parsed_instance_group
            expect(instance_group.vm_type.name).to eq('fake-vm-type')
            expect(instance_group.vm_type.cloud_properties).to eq({})
            expect(instance_group.stemcell.name).to eq('fake-stemcell-name')
            expect(instance_group.stemcell.version).to eq('1')
            expect(instance_group.env.spec).to eq({'key' => 'value'})
          end

          context 'when env is also declared in the job spec' do
            before do
              instance_group_spec['env'] = {'env1' => 'something'}
              expect(deployment_plan).to receive(:resource_pool)
                                           .with('fake-resource-pool-name')
                                           .and_return(resource_pool)
            end

            it 'complains' do
              expect {
                parsed_instance_group
              }.to raise_error(
                InstanceGroupAmbiguousEnv,
                "Instance group 'instance-group-name' and resource pool: 'fake-resource-pool-name' both declare env properties"
              )
            end
          end

          context 'when the job declares env, and the resource pool does not' do
            let(:resource_pool_env) { {} }
            before do
              instance_group_spec['env'] = {'job' => 'env'}
              expect(deployment_plan).to receive(:resource_pool)
                                           .with('fake-resource-pool-name')
                                           .and_return(resource_pool)
            end

            it 'should assign the job env to the job' do
              instance_group = parsed_instance_group
              expect(instance_group.env.spec).to eq({'job' => 'env'})
            end
          end

          it 'complains about unknown resource pool' do
            instance_group_spec['resource_pool'] = 'unknown-resource-pool'
            expect(deployment_plan).to receive(:resource_pool)
                                         .with('unknown-resource-pool')
                                         .and_return(nil)

            expect {
              parsed_instance_group
            }.to raise_error(
              InstanceGroupUnknownResourcePool,
              "Instance group 'instance-group-name' references an unknown resource pool 'unknown-resource-pool'"
            )
          end
        end

        describe 'vm type and stemcell key' do
          before do
            allow(deployment_plan).to receive(:vm_type).with('fake-vm-type').and_return(
              VmType.new({
                'name' => 'fake-vm-type',
                'cloud_properties' => {}
              })
            )
            allow(deployment_plan).to receive(:stemcell).with('fake-stemcell').and_return(
              Stemcell.parse({
                'alias' => 'fake-stemcell',
                'os' => 'fake-os',
                'version' => 1
              })
            )
          end

          let(:instance_group_spec) do
            {
              'name' => 'instance-group-name',
              'templates' => [],
              'release' => 'fake-release-name',
              'vm_type' => 'fake-vm-type',
              'stemcell' => 'fake-stemcell',
              'env' => {'key' => 'value'},
              'instances' => 1,
              'networks' => [{'name' => 'fake-network-name'}]
            }
          end

          it 'parses vm type and stemcell' do
            instance_group = parsed_instance_group
            expect(instance_group.vm_type.name).to eq('fake-vm-type')
            expect(instance_group.vm_type.cloud_properties).to eq({})
            expect(instance_group.stemcell.alias).to eq('fake-stemcell')
            expect(instance_group.stemcell.version).to eq('1')
            expect(instance_group.env.spec).to eq({'key' => 'value'})
          end

          context 'vm type cannot be found' do
            before do
              allow(deployment_plan).to receive(:vm_type).with('fake-vm-type').and_return(nil)
            end

            it 'errors out' do
              expect { parsed_instance_group }.to raise_error(
                InstanceGroupUnknownVmType,
                "Instance group 'instance-group-name' references an unknown vm type 'fake-vm-type'"
              )
            end
          end

          context 'stemcell cannot be found' do
            before do
              allow(deployment_plan).to receive(:stemcell).with('fake-stemcell').and_return(nil)
            end

            it 'errors out' do
              expect { parsed_instance_group }.to raise_error(
                InstanceGroupUnknownStemcell,
                "Instance group 'instance-group-name' references an unknown stemcell 'fake-stemcell'"
              )
            end
          end

        end

        describe 'vm resources' do
          let(:vm_resources) do
            {
              'vm_resources' => {
                'cpu' => 4,
                'ram' => 2048,
                'ephemeral_disk_size' => 100
              }
            }
          end

          before do
            allow(deployment_plan).to receive(:stemcell).with('fake-stemcell').and_return(
              Stemcell.parse({
                'alias' => 'fake-stemcell',
                'os' => 'fake-os',
                'version' => 1
              })
            )
          end

          let(:instance_group_spec) do
            {
              'name' => 'instance-group-name',
              'templates' => [],
              'release' => 'fake-release-name',
              'stemcell' => 'fake-stemcell',
              'env' => {'key' => 'value'},
              'instances' => 1,
              'networks' => [{'name' => 'fake-network-name'}]
            }
          end

          context 'when vm_resources are given' do
            before do
              instance_group_spec.merge!(vm_resources)
            end

            it 'parses the vm resources' do
              instance_group = nil
              expect {
                instance_group = parsed_instance_group
              }.to_not raise_error
              expect(instance_group.vm_resources.cpu).to eq(4)
              expect(instance_group.vm_resources.ram).to eq(2048)
              expect(instance_group.vm_resources.ephemeral_disk_size).to eq(100)
            end
          end

          context 'when more than one vm config is given' do
            let(:resource_pool_config) { { 'resource_pool' => 'fake-resource-pool' } }
            let(:vm_type) { { 'vm_type' => 'fake-vm-type' } }

            before do
              allow(deployment_plan).to receive(:vm_type).with('fake-vm-type').and_return(
                VmType.new('name' => 'fake-vm-type', 'cloud_properties' => {})
              )
            end

            it 'raises an error for vm_type, vm_resources, resource_pool' do
              instance_group_spec.merge!(resource_pool_config).merge!(vm_type).merge!(vm_resources)

              expect {
                parsed_instance_group
              }.to raise_error(InstanceGroupBadVmConfiguration, "Instance group 'instance-group-name' can only specify one of 'resource_pool', 'vm_type' or 'vm_resources' keys.")
            end

            it 'raises an error for vm_type, vm_resources' do
              instance_group_spec.merge!(vm_type).merge!(vm_resources)

              expect {
                parsed_instance_group
              }.to raise_error(InstanceGroupBadVmConfiguration, "Instance group 'instance-group-name' can only specify one of 'resource_pool', 'vm_type' or 'vm_resources' keys.")
            end

            it 'raises an error for resource_pool, vm_resources' do
              instance_group_spec.merge!(resource_pool_config).merge!(vm_resources)

              expect {
                parsed_instance_group
              }.to raise_error(InstanceGroupBadVmConfiguration, "Instance group 'instance-group-name' can only specify one of 'resource_pool', 'vm_type' or 'vm_resources' keys.")
            end

            it 'raises an error for resource_pool, vm_type' do
              instance_group_spec.merge!(resource_pool_config).merge!(vm_type)

              expect {
                parsed_instance_group
              }.to raise_error(InstanceGroupBadVmConfiguration, "Instance group 'instance-group-name' can only specify one of 'resource_pool', 'vm_type' or 'vm_resources' keys.")
            end
          end

          context 'when neither vm type, vm resources nor resource pool are given' do
            it 'raises an error' do
              expect {
                parsed_instance_group
              }.to raise_error(InstanceGroupBadVmConfiguration, "Instance group 'instance-group-name' is missing either 'vm_type' or 'vm_resources' or 'resource_pool' section.")
            end
          end

        end

        describe 'vm_extensions key' do

          let(:vm_extension_1) do
            {
              'name' => 'vm_extension_1',
              'cloud_properties' => {'property' => 'value'}
            }
          end

          let(:vm_extension_2) do
            {
              'name' => 'vm_extension_2',
              'cloud_properties' => {'another_property' => 'value1', 'property' => 'value2'}
            }
          end

          let(:instance_group_spec) do
            {
              'name' => 'instance-group-name',
              'templates' => [],
              'release' => 'fake-release-name',
              'vm_type' => 'fake-vm-type',
              'stemcell' => 'fake-stemcell',
              'env' => {'key' => 'value'},
              'instances' => 1,
              'networks' => [{'name' => 'fake-network-name'}]
            }
          end

          before do
            allow(deployment_plan).to receive(:vm_type).with('fake-vm-type').and_return(
              VmType.new({
                'name' => 'fake-vm-type',
                'cloud_properties' => {}
              })
            )
            allow(deployment_plan).to receive(:stemcell).with('fake-stemcell').and_return(
              Stemcell.parse({
                'alias' => 'fake-stemcell',
                'os' => 'fake-os',
                'version' => 1
              })
            )
            allow(deployment_plan).to receive(:vm_extension).with('vm_extension_1').and_return(
              VmExtension.new(vm_extension_1)
            )
            allow(deployment_plan).to receive(:vm_extension).with('vm_extension_2').and_return(
              VmExtension.new(vm_extension_2)
            )
          end

          context 'job has one vm_extension' do
            it 'parses the vm_extension' do
              instance_group_spec['vm_extensions'] = ['vm_extension_1']

              instance_group = parsed_instance_group
              expect(instance_group.vm_extensions.size).to eq(1)
              expect(instance_group.vm_extensions.first.name).to eq('vm_extension_1')
              expect(instance_group.vm_extensions.first.cloud_properties).to eq({'property' => 'value'})

            end
          end
        end

        describe 'properties key' do
          context 'properties mapping' do
            it 'complains about unsatisfiable property mappings' do
              props = {'foo' => 'bar'}

              instance_group_spec['properties'] = props
              instance_group_spec['property_mappings'] = {'db' => 'ccdb'}

              allow(deployment_plan).to receive(:properties).and_return(props)

              expect {
                parsed_instance_group
              }.to raise_error(
                InstanceGroupInvalidPropertyMapping,
              )
            end

            it 'maps properties correctly' do

              props = {
                'ccdb' => {
                  'user' => 'admin',
                  'password' => '12321',
                  'unused' => 'yada yada'
                },
                'dea' => {
                  'max_memory' => 2048
                }
              }

              instance_group_spec['properties'] = props
              instance_group_spec['property_mappings'] = {'db' => 'ccdb', 'mem' => 'dea.max_memory'}

              allow(deployment_plan).to receive(:properties).and_return(props)

              parsed_instance_group
            end
          end
        end

        describe 'instances key' do
          it 'parses out desired instances' do
            instance_group = parsed_instance_group

            expect(instance_group.desired_instances).to eq([
              DesiredInstance.new(instance_group, deployment_plan),
            ])
          end
        end

        describe 'networks key' do
          before { instance_group_spec['networks'].first['static_ips'] = '10.0.0.2 - 10.0.0.4' } # 2,3,4

          context 'when the number of static ips is less than number of instances' do
            it 'raises an exception because if a job uses static ips all instances must have a static ip' do
              instance_group_spec['instances'] = 4
              expect {
                parsed_instance_group
              }.to raise_error(
                InstanceGroupNetworkInstanceIpMismatch,
                "Instance group 'instance-group-name' has 4 instances but was allocated 3 static IPs in network 'fake-network-name'",
              )
            end
          end

          context 'when the number of static ips is greater the number of instances' do
            it 'raises an exception because the extra ip is wasted' do
              instance_group_spec['instances'] = 2
              expect {
                parsed_instance_group
              }.to raise_error(
                InstanceGroupNetworkInstanceIpMismatch,
                "Instance group 'instance-group-name' has 2 instances but was allocated 3 static IPs in network 'fake-network-name'",
              )
            end
          end

          context 'when number of static ips matches the number of instances' do
            it 'does not raise an exception' do
              instance_group_spec['instances'] = 3
              expect { parsed_instance_group }.to_not raise_error
            end
          end

          context 'when there are multiple networks specified as default for a property' do
            it 'errors' do
              instance_group_spec['instances'] = 3
              instance_group_spec['networks'].first['default'] = ['gateway', 'dns']
              instance_group_spec['networks'] << instance_group_spec['networks'].first.merge('name' => 'duped-network') # dupe it
              duped_network = ManualNetwork.new('duped-network', [], logger)
              allow(deployment_plan).to receive(:networks).and_return([duped_network, network])

              expect {
                parsed_instance_group
              }.to raise_error(
                JobNetworkMultipleDefaults,
                "Instance group 'instance-group-name' specified more than one network to contain default. " +
                  "'dns' has default networks: 'fake-network-name', 'duped-network'. "+
                  "'gateway' has default networks: 'fake-network-name', 'duped-network'."
              )
            end
          end

          context 'when there are no networks specified as default for a property' do
            context 'when there is only one network' do
              it 'picks the only network as default' do
                instance_group_spec['instances'] = 3
                allow(deployment_plan).to receive(:networks).and_return([network])
                instance_group = parsed_instance_group

                expect(instance_group.default_network['dns']).to eq('fake-network-name')
                expect(instance_group.default_network['gateway']).to eq('fake-network-name')
              end
            end

            context 'when there are two networks, each being a separate default' do
              let(:network2) { ManualNetwork.new('fake-network-name-2', [], logger) }

              it 'picks the only network as default' do
                instance_group_spec['networks'].first['default'] = ['dns']
                instance_group_spec['networks'] << {'name' => 'fake-network-name-2', 'default' => ['gateway']}
                instance_group_spec['instances'] = 3
                allow(deployment_plan).to receive(:networks).and_return([network, network2])
                instance_group = parsed_instance_group

                expect(instance_group.default_network['dns']).to eq('fake-network-name')
                expect(instance_group.default_network['gateway']).to eq('fake-network-name-2')
              end
            end

          end
        end

        describe 'azs key' do
          context 'when there is a key but empty values' do
            it 'raises an exception' do
              instance_group_spec['azs'] = []

              expect {
                parsed_instance_group
              }.to raise_error(
                JobMissingAvailabilityZones, "Instance group 'instance-group-name' has empty availability zones"
              )
            end
          end

          context 'when there is a key with values' do
            it 'parses each value into the AZ on the deployment' do
              zone1, zone2 = set_up_azs!(['zone1', 'zone2'], instance_group_spec, deployment_plan)
              allow(network).to receive(:has_azs?).and_return(true)
              expect(parsed_instance_group.availability_zones).to eq([zone1, zone2])
            end

            it 'raises an exception if the value are not strings' do
              instance_group_spec['azs'] = ['valid_zone', 3]
              allow(network).to receive(:has_azs?).and_return(true)
              allow(deployment_plan).to receive(:availability_zone).with('valid_zone') { instance_double(AvailabilityZone) }

              expect {
                parsed_instance_group
              }.to raise_error(
                JobInvalidAvailabilityZone, "Instance group 'instance-group-name' has invalid availability zone '3', string expected"
              )
            end

            it 'raises an exception if the referenced AZ doesnt exist in the deployment' do
              instance_group_spec['azs'] = ['existent_zone', 'nonexistent_zone']
              allow(network).to receive(:has_azs?).and_return(true)
              allow(deployment_plan).to receive(:availability_zone).with('existent_zone') { instance_double(AvailabilityZone) }
              allow(deployment_plan).to receive(:availability_zone).with('nonexistent_zone') { nil }

              expect {
                parsed_instance_group
              }.to raise_error(
                JobUnknownAvailabilityZone, "Instance group 'instance-group-name' references unknown availability zone 'nonexistent_zone'"
              )
            end

            it 'raises an error if the referenced AZ is not specified on networks' do
              allow(network).to receive(:has_azs?).and_return(false)

              expect {
                parsed_instance_group
              }.to raise_error(
                JobNetworkMissingRequiredAvailabilityZone,
                "Instance group 'instance-group-name' must specify availability zone that matches availability zones of network 'fake-network-name'"
              )
            end

            describe 'validating AZs against the networks of the job' do
              it 'validates that every network satisfies job AZ requirements' do
                set_up_azs!(['zone1', 'zone2'], instance_group_spec, deployment_plan)
                instance_group_spec['networks'] = [
                  {'name' => 'first-network'},
                  {'name' => 'second-network', 'default' => ['dns', 'gateway']}
                ]

                first_network = instance_double(
                  ManualNetwork,
                  name: 'first-network',
                  has_azs?: true,
                  validate_reference_from_job!: true
                )
                second_network = instance_double(
                  ManualNetwork,
                  name: 'second-network',
                  has_azs?: true,
                  validate_reference_from_job!: true
                )
                allow(deployment_plan).to receive(:networks).and_return([first_network, second_network])

                parsed_instance_group

                expect(first_network).to have_received(:has_azs?).with(['zone1', 'zone2'])
                expect(second_network).to have_received(:has_azs?).with(['zone1', 'zone2'])
              end
            end
          end

          context 'when there is a key with the wrong type' do
            it 'an exception is raised' do
              instance_group_spec['azs'] = 3

              expect {
                parsed_instance_group
              }.to raise_error(
                ValidationInvalidType, "Property 'azs' value (3) did not match the required type 'Array'"
              )
            end
          end
        end

        describe 'migrated_from' do
          let(:instance_group_spec) do
            {
              'name' => 'instance-group-name',
              'templates' => [],
              'release' => 'fake-release-name',
              'resource_pool' => 'fake-resource-pool-name',
              'instances' => 1,
              'networks' => [{'name' => 'fake-network-name'}],
              'migrated_from' => [{'name' => 'job-1', 'az' => 'z1'}, {'name' => 'job-2', 'az' => 'z2'}],
              'azs' => ['z1', 'z2']
            }
          end
          before do
            allow(network).to receive(:has_azs?).and_return(true)
            allow(deployment_plan).to receive(:availability_zone).with('z1') { AvailabilityZone.new('z1', {}) }
            allow(deployment_plan).to receive(:availability_zone).with('z2') { AvailabilityZone.new('z2', {}) }
          end

          it 'sets migrated_from on a job' do
            instance_group = parsed_instance_group
            expect(instance_group.migrated_from[0].name).to eq('job-1')
            expect(instance_group.migrated_from[0].availability_zone).to eq('z1')
            expect(instance_group.migrated_from[1].name).to eq('job-2')
            expect(instance_group.migrated_from[1].availability_zone).to eq('z2')
          end

          context 'when az is specified' do
            context 'when migrated job refers to az that is not in the list of availaibility_zones key' do
              it 'raises an error' do
                instance_group_spec['migrated_from'] = [{'name' => 'job-1', 'az' => 'unknown_az'}]

                expect {
                  parsed_instance_group
                }.to raise_error(
                  DeploymentInvalidMigratedFromJob,
                  "Instance group 'job-1' specified for migration to instance group 'instance-group-name' refers to availability zone 'unknown_az'. " +
                    "Az 'unknown_az' is not in the list of availability zones of instance group 'instance-group-name'."
                )
              end
            end
          end
        end

        describe 'remove_dev_tools' do
          let(:resource_pool_env) { {} }
          before { allow(Config).to receive(:remove_dev_tools).and_return(false) }

          it 'does not add remove_dev_tools by default' do
            instance_group = parsed_instance_group
            expect(instance_group.env.spec['bosh']).to eq(nil)
          end

          it 'does what the job env says' do
            instance_group_spec['env'] = {'bosh' => {'remove_dev_tools' => 'custom'}}
            instance_group = parsed_instance_group
            expect(instance_group.env.spec['bosh']['remove_dev_tools']).to eq('custom')
          end

          describe 'when director manifest specifies director.remove_dev_tools' do
            before { allow(Config).to receive(:remove_dev_tools).and_return(true) }

            it 'should do what director wants' do
              instance_group = parsed_instance_group
              expect(instance_group.env.spec['bosh']['remove_dev_tools']).to eq(true)
            end
          end

          describe 'when both the job and director specify' do
            before do
              allow(Config).to receive(:remove_dev_tools).and_return(true)
              instance_group_spec['env'] = {'bosh' => {'remove_dev_tools' => false}}
            end

            it 'defers to the job' do
              instance_group = parsed_instance_group
              expect(instance_group.env.spec['bosh']['remove_dev_tools']).to eq(false)
            end
          end
        end

        describe 'update' do
          let(:update) { {} }

          before do
            instance_group_spec['update'] = update
          end

          it 'can be overridden by canaries option' do
            parse_options['canaries'] = 7

            expect(parsed_instance_group.update.canaries(nil)).to eq(7)
          end

          it 'can be overridden by max-in-flight option' do
            parse_options['max_in_flight'] = 8

            expect(parsed_instance_group.update.max_in_flight(nil)).to eq(8)
          end

          context 'when provided an instance_group_spec with a strategy' do
            let(:update) { {'strategy' => 'hot-swap'} }

            it 'should set the instance_group strategy as hot-swap' do
              expect(parsed_instance_group.update.strategy).to eq('hot-swap')
            end

          end
        end

        def set_up_azs!(azs, instance_group_spec, deployment_plan)
          instance_group_spec['azs'] = azs
          azs.map do |az_name|
            fake_az = instance_double(AvailabilityZone, name: az_name)
            allow(deployment_plan).to receive(:availability_zone).with(az_name) { fake_az }
            fake_az
          end
        end

        def make_job(name, rel_ver)
          instance_double(
            Job,
            name: name,
            release: rel_ver,
            link_infos: {}
          )
        end
      end
    end
  end
end
